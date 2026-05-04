#!/usr/bin/env bash
# dfe-install.sh - Instalador idempotente para systemd
# Estado salvo em <INSTALL_DIR>/.dfe-setup.env (KEY=VALUE, sem jq)
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_state.sh
source "${SCRIPT_DIR}/_state.sh"

DEFAULT_USER="dfeconv"
DEFAULT_GROUP="$DEFAULT_USER"
DEFAULT_CONFIG_NAME="config.properties"
DEFAULT_JAVA_OPTS="-Dapp.headless=true"
DEFAULT_LIMIT_NOFILE=65536

# Os defaults de service/dir/jar são definidos após o parse de --ambiente
DEFAULT_SERVICE=""
DEFAULT_INSTALL_DIR=""
DEFAULT_JAR_NAME=""

AUTO_YES=false
NO_START=false
FORCE=false
JAR_SOURCE=""
CONFIG_SOURCE=""
INSTALL_DIR=""
VERSAO_ARG=""
AMBIENTE_ARG="QA"
JAVA_HOME_ARG=""

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

print_help() {
  cat <<EOF
Uso: sudo $0 [--yes] [--install-dir PATH] [--jar-source PATH] [--config-source PATH]
             [--versao VERSAO] [--ambiente QA|PROD] [--java-home PATH] [--no-start] [--force] [-h]

--yes            Aceita todos os defaults sem perguntas
--install-dir    Diretório de instalação
--jar-source     Caminho para o JAR de origem
--config-source  Caminho para config.properties (opcional)
--versao         Versão do JAR (ex: 2.38) para registrar no estado
--ambiente       QA ou PROD (padrão: QA)
--java-home      Diretório raiz do Java a usar (ex: /opt/DFE_CONVERTER_QA/java)
--no-start       Não iniciar/ativar o service após instalar
--force          Sobrescrever unit/env sem perguntar
-h, --help       Mostra esta ajuda
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)          AUTO_YES=true; shift;;
    --install-dir)  INSTALL_DIR="$2"; shift 2;;
    --jar-source)   JAR_SOURCE="$2"; shift 2;;
    --config-source) CONFIG_SOURCE="$2"; shift 2;;
    --versao)       VERSAO_ARG="$2"; shift 2;;
    --ambiente)     AMBIENTE_ARG="${2^^}"; shift 2;;
    --java-home)    JAVA_HOME_ARG="$2"; shift 2;;
    --no-start)     NO_START=true; shift;;
    --force)        FORCE=true; shift;;
    -h|--help)      print_help; exit 0;;
    *)              echo "Opção desconhecida: $1"; print_help; exit 1;;
  esac
done

# Ajusta defaults de acordo com o ambiente selecionado
case "${AMBIENTE_ARG^^}" in
  PROD)
    DEFAULT_SERVICE="${DEFAULT_SERVICE:-dfe-converter-prod}"
    DEFAULT_INSTALL_DIR="${DEFAULT_INSTALL_DIR:-/opt/DFE_CONVERTER_PROD}"
    DEFAULT_JAR_NAME="${DEFAULT_JAR_NAME:-DFe-Converter-PROD.jar}"
    ;;
  *)
    DEFAULT_SERVICE="${DEFAULT_SERVICE:-dfe-converter-qa}"
    DEFAULT_INSTALL_DIR="${DEFAULT_INSTALL_DIR:-/opt/DFE_CONVERTER_QA}"
    DEFAULT_JAR_NAME="${DEFAULT_JAR_NAME:-DFe-Converter-QA.jar}"
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: execute como root (sudo)."
  exit 1
fi

ask_default() {
  local question="$1" default="$2" reply
  if $AUTO_YES; then echo "$default"; return 0; fi
  read -rp "$question [$default]: " reply
  if [[ -z "$reply" ]]; then echo "$default"; else echo "$reply"; fi
}

ask_yesno() {
  local question="$1" default="$2" ans
  if $AUTO_YES; then [[ "$default" = "y" ]] && return 0 || return 1; fi
  while true; do
    read -rp "$question [$default] (y/n): " ans
    ans="${ans:-$default}"
    case "${ans,,}" in
      y|yes) return 0;;
      n|no)  return 1;;
      *) echo "Resposta inválida (y/n)";;
    esac
  done
}

SERVICE_NAME="$(ask_default 'Nome do service (systemd unit)' "$DEFAULT_SERVICE")"
SERVICE_NAME="${SERVICE_NAME%.service}"
USER_NAME="$(ask_default 'Usuário do sistema para rodar o service' "$DEFAULT_USER")"
GROUP_NAME="$USER_NAME"
INSTALL_DIR="$(ask_default 'Diretório de instalação' "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}")"

# JAR source
if [[ -n "$JAR_SOURCE" ]]; then
  echo "Usando JAR informado via CLI: $JAR_SOURCE"
else
  if [[ -f "./$DEFAULT_JAR_NAME" ]]; then
    JAR_SOURCE="$(ask_default 'Caminho para o JAR de origem' "./$DEFAULT_JAR_NAME")"
  else
    while true; do
      JAR_SOURCE="$(ask_default 'Caminho para o JAR de origem (obrigatório)' "./$DEFAULT_JAR_NAME")"
      if [[ -f "$JAR_SOURCE" ]]; then break; fi
      echo "Arquivo JAR não encontrado: $JAR_SOURCE"
      ask_yesno "Tentar outro caminho?" "y" || { echo "Abortando: JAR é obrigatório."; exit 1; }
    done
  fi
fi

# Config source
if [[ -n "$CONFIG_SOURCE" ]]; then
  echo "Usando config informado via CLI: $CONFIG_SOURCE"
else
  if ask_yesno "Você possui um config.properties para copiar?" "y"; then
    while true; do
      CONFIG_SOURCE="$(ask_default 'Caminho para o config' "./$DEFAULT_CONFIG_NAME")"
      if [[ -z "$CONFIG_SOURCE" ]]; then CONFIG_SOURCE=""; break; fi
      if [[ -f "$CONFIG_SOURCE" ]]; then break; fi
      echo "Arquivo não encontrado: $CONFIG_SOURCE"
      ask_yesno "Tentar outro caminho?" "y" || { CONFIG_SOURCE=""; break; }
    done
  else
    CONFIG_SOURCE=""
  fi
fi

JAR_NAME="$(ask_default 'Nome do JAR no destino' "$DEFAULT_JAR_NAME")"
CONFIG_NAME="$(ask_default 'Nome do config no destino' "$DEFAULT_CONFIG_NAME")"
JAVA_OPTS="$(ask_default 'JAVA_OPTS' "$DEFAULT_JAVA_OPTS")"

# Checksum helpers
sha256_of_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    echo ""
  fi
}

file_differs() {
  local src="$1" dst="$2"
  if [[ ! -f "$dst" ]]; then return 0; fi
  local s_sum d_sum
  s_sum="$(sha256_of_file "$src" || true)"
  d_sum="$(sha256_of_file "$dst" || true)"
  if [[ -n "$s_sum" && -n "$d_sum" ]]; then
    [[ "$s_sum" != "$d_sum" ]] && return 0 || return 1
  else
    if command -v cmp >/dev/null 2>&1; then
      ! cmp -s "$src" "$dst"
      return $?
    fi
    return 0
  fi
}

backup_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    local b="${path}.bak.$(date +%s)"
    echo "Backup: $path -> $b"
    cp -p -- "$path" "$b"
  fi
}

detect_init() {
  if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
    echo "systemd"
  elif [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  else
    echo "other"
  fi
}
INIT_SYSTEM="$(detect_init)"

# Create user/group if needed
if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
  groupadd --system "$GROUP_NAME"
fi
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /sbin/nologin --gid "$GROUP_NAME" "$USER_NAME"
fi

mkdir -p "$INSTALL_DIR"
chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR"

# Se há java embarcado na pasta de instalação, garantir permissões corretas
if [[ -n "$JAVA_HOME_ARG" && -d "$JAVA_HOME_ARG" ]]; then
  chown -R "$USER_NAME:$GROUP_NAME" "$JAVA_HOME_ARG"
  chmod -R a+rX "$JAVA_HOME_ARG"
  find "$JAVA_HOME_ARG/bin" -type f -exec chmod a+x {} \; 2>/dev/null || true
fi

DEST_JAR="${INSTALL_DIR%/}/${JAR_NAME}"
JAR_CHANGED=false
if file_differs "$JAR_SOURCE" "$DEST_JAR"; then
  cp -f -- "$JAR_SOURCE" "$DEST_JAR"
  chown "$USER_NAME:$GROUP_NAME" "$DEST_JAR"
  chmod 0550 "$DEST_JAR"
  JAR_CHANGED=true
else
  echo "JAR idêntico; não será copiado."
fi

JAR_CHECKSUM="$(sha256_of_file "$DEST_JAR" || echo "")"

CONFIG_CHANGED=false
if [[ -n "$CONFIG_SOURCE" ]]; then
  DEST_CONFIG="${INSTALL_DIR%/}/${CONFIG_NAME}"
  if file_differs "$CONFIG_SOURCE" "$DEST_CONFIG"; then
    cp -f -- "$CONFIG_SOURCE" "$DEST_CONFIG"
    chown "$USER_NAME:$GROUP_NAME" "$DEST_CONFIG"
    chmod 0640 "$DEST_CONFIG"
    CONFIG_CHANGED=true
  else
    echo "Config idêntico; não será copiado."
  fi
fi

# systemd unit
ENV_FILE="/etc/default/${SERVICE_NAME}"
# Se --java-home foi fornecido, aponta JAVA_CMD para o binário embarcado
JAVA_CMD_VALUE=""
if [[ -n "$JAVA_HOME_ARG" ]]; then
  JAVA_CMD_VALUE="${JAVA_HOME_ARG%/}/bin/java"
fi
ENV_CONTENT="# /etc/default/${SERVICE_NAME}
JAVA_CMD=${JAVA_CMD_VALUE}
JAVA_OPTS=\"${JAVA_OPTS}\"
EXTRA_OPTS=\"\"
"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
UNIT_CONTENT="[Unit]
Description=${SERVICE_NAME}
After=network.target

[Service]
Type=simple
User=${USER_NAME}
Group=${GROUP_NAME}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-/etc/default/${SERVICE_NAME}
ExecStart=/bin/sh -c 'exec \"\${JAVA_CMD:-java}\" \${JAVA_OPTS} -jar \"${DEST_JAR}\" --sync.config.file=\"${INSTALL_DIR}/${CONFIG_NAME}\" \${EXTRA_OPTS:-}'
Restart=on-failure
RestartSec=10
LimitNOFILE=${DEFAULT_LIMIT_NOFILE}

[Install]
WantedBy=multi-user.target
"

ENV_CHANGED=false
if [[ -f "$ENV_FILE" ]]; then
  if ! printf "%s" "$ENV_CONTENT" | cmp -s - "$ENV_FILE"; then
    if [[ "$FORCE" = true ]] || ask_yesno "Sobrescrever $ENV_FILE?" "n"; then
      backup_if_exists "$ENV_FILE"
      printf "%s" "$ENV_CONTENT" > "$ENV_FILE"
      chmod 0644 "$ENV_FILE"
      ENV_CHANGED=true
    fi
  fi
else
  printf "%s" "$ENV_CONTENT" > "$ENV_FILE"
  chmod 0644 "$ENV_FILE"
  ENV_CHANGED=true
fi

UNIT_CHANGED=false
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  if [[ -f "$UNIT_PATH" ]]; then
    if ! printf "%s" "$UNIT_CONTENT" | cmp -s - "$UNIT_PATH"; then
      if [[ "$FORCE" = true ]] || ask_yesno "Sobrescrever unit $UNIT_PATH?" "n"; then
        backup_if_exists "$UNIT_PATH"
        printf "%s" "$UNIT_CONTENT" > "$UNIT_PATH"
        chmod 0644 "$UNIT_PATH"
        UNIT_CHANGED=true
      fi
    fi
  else
    printf "%s" "$UNIT_CONTENT" > "$UNIT_PATH"
    chmod 0644 "$UNIT_PATH"
    UNIT_CHANGED=true
  fi
fi

if [[ "$INIT_SYSTEM" == "systemd" && ( "$UNIT_CHANGED" = true || "$ENV_CHANGED" = true ) ]]; then
  systemctl daemon-reload
fi

SERVICE_ACTIVE=false
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    SERVICE_ACTIVE=true
  fi
fi

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  if $SERVICE_ACTIVE; then
    if [[ "$JAR_CHANGED" = true || "$CONFIG_CHANGED" = true || "$UNIT_CHANGED" = true || "$ENV_CHANGED" = true ]]; then
      systemctl restart "${SERVICE_NAME}.service" || echo "Aviso: falha ao reiniciar."
    fi
  else
    if ! $NO_START; then
      systemctl enable --now "${SERVICE_NAME}.service" || echo "Aviso: falha ao iniciar/habilitar."
    fi
  fi
else
  echo "Sistema não usa systemd; unidade criada mas não gerenciada automaticamente."
fi

# --- Save state to .dfe-setup.env (replaces old .dfe-setup.json) ---
CFG_FILE="${INSTALL_DIR%/}/.dfe-setup.env"
_state_init "$CFG_FILE"
JAVA_PATH="$(command -v java || echo '')"
INSTALLED_BY="${SUDO_USER:-$(whoami)}"

_state_write DFE_SERVICE_NAME  "$SERVICE_NAME"          "$CFG_FILE"
_state_write DFE_JAR_NAME      "$JAR_NAME"              "$CFG_FILE"
_state_write DFE_CONFIG_NAME   "$CONFIG_NAME"           "$CFG_FILE"
_state_write DFE_JAVA_PATH     "$JAVA_PATH"             "$CFG_FILE"
_state_write DFE_JAVA_HOME     "${JAVA_HOME_ARG:-}"     "$CFG_FILE"
_state_write DFE_LOGS_ENABLED  "false"                  "$CFG_FILE"
_state_write DFE_INSTALL_DIR   "$INSTALL_DIR"           "$CFG_FILE"
_state_write DFE_INSTALLED_AT  "$(timestamp)"           "$CFG_FILE"
_state_write DFE_INSTALLED_BY  "$INSTALLED_BY"          "$CFG_FILE"
_state_write DFE_OS            "linux"                  "$CFG_FILE"
_state_write DFE_VERSAO        "${VERSAO_ARG:-}"        "$CFG_FILE"
_state_write DFE_AMBIENTE      "$AMBIENTE_ARG"          "$CFG_FILE"
_state_write DFE_CHECKSUM_SHA256 "$JAR_CHECKSUM"        "$CFG_FILE"

echo
echo "Resumo:"
echo " Service:        ${SERVICE_NAME}"
echo " Install dir:    ${INSTALL_DIR}"
echo " JAR changed:    ${JAR_CHANGED}"
echo " Config changed: ${CONFIG_CHANGED}"
echo " Unit changed:   ${UNIT_CHANGED}"
echo " Env changed:    ${ENV_CHANGED}"
echo " Estado:         ${CFG_FILE}"
echo
echo "Concluído."
exit 0
