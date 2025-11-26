#!/usr/bin/env bash
# dfe-install.sh - Instalador idempotente para systemd (escreve <INSTALL_DIR>/.dfe-setup.json)
# Requer: jq
set -o errexit
set -o nounset
set -o pipefail

DEFAULT_SERVICE="dfe-converter-qa"
DEFAULT_USER="dfeconv"
DEFAULT_GROUP="$DEFAULT_USER"
DEFAULT_INSTALL_DIR="/opt/DFE_CONVERTER_QA"
DEFAULT_JAR_NAME="DFe-Converter-QA.jar"
DEFAULT_CONFIG_NAME="config.properties"
DEFAULT_JAVA_OPTS="-Dapp.headless=true"
DEFAULT_LIMIT_NOFILE=65536

AUTO_YES=false
NO_START=false
FORCE=false
JAR_SOURCE=""
CONFIG_SOURCE=""
INSTALL_DIR=""

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

print_help() {
  cat <<EOF
Uso: sudo $0 [--yes] [--install-dir PATH] [--jar-source PATH] [--config-source PATH] [--no-start] [--force] [-h]

--yes            Aceita todos os defaults sem perguntas
--install-dir    Diretório de instalação (ex: /opt/DFE_CONVERTER_QA)
--jar-source     Caminho para o JAR de origem (obrigatório se não houver JAR no dir atual)
--config-source  Caminho para config.properties (opcional)
--no-start       Não iniciar/ativar o serviço após instalar
--force          Sobrescrever unit/env sem perguntar
-h, --help       Mostra essa ajuda
EOF
}

# args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) AUTO_YES=true; shift;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --jar-source) JAR_SOURCE="$2"; shift 2;;
    --config-source) CONFIG_SOURCE="$2"; shift 2;;
    --no-start) NO_START=true; shift;;
    --force) FORCE=true; shift;;
    -h|--help) print_help; exit 0;;
    *) echo "Opcao desconhecida: $1"; print_help; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: execute este script como root (sudo)."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  cat >&2 <<'ERR'
ERRO: este script usa 'jq' para manipular JSON.
Instale jq primeiro. Exemplos:
  Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y jq
  RHEL/CentOS: sudo dnf install -y jq  (ou yum install via EPEL)
  Arch: sudo pacman -S jq

Depois reexecute o instalador.
ERR
  exit 1
fi

ask_default() {
  local question="$1" default="$2" reply
  if $AUTO_YES; then
    echo "$default"
    return 0
  fi
  read -rp "$question [$default]: " reply
  if [[ -z "$reply" ]]; then
    echo "$default"
  else
    echo "$reply"
  fi
}
ask_yesno() {
  local question="$1" default="$2" ans
  if $AUTO_YES; then
    [[ "$default" = "y" ]] && return 0 || return 1
  fi
  while true; do
    read -rp "$question [$default] (y/n): " ans
    ans="${ans:-$default}"
    case "${ans,,}" in
      y|yes) return 0;;
      n|no) return 1;;
      *) echo "Resposta inválida (y/n)";;
    esac
  done
}

SERVICE_NAME="$(ask_default 'Nome do serviço (systemd unit)' "$DEFAULT_SERVICE")"
SERVICE_NAME="${SERVICE_NAME%.service}"
USER_NAME="$(ask_default 'Usuário do sistema para rodar o serviço' "$DEFAULT_USER")"
GROUP_NAME="$USER_NAME"
INSTALL_DIR="$(ask_default 'Diretório de instalação' "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}")"

# JAR source required
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

# Config source optional
if [[ -n "$CONFIG_SOURCE" ]]; then
  echo "Usando config informado via CLI: $CONFIG_SOURCE"
else
  if ask_yesno "Você possui um config.properties para copiar?" "y"; then
    while true; do
      CONFIG_SOURCE="$(ask_default 'Caminho para o config (ou ENTER para pular)' "./$DEFAULT_CONFIG_NAME")"
      if [[ -z "$CONFIG_SOURCE" ]]; then CONFIG_SOURCE=""; break; fi
      if [[ -f "$CONFIG_SOURCE" ]]; then break; fi
      echo "Arquivo de config não encontrado: $CONFIG_SOURCE"
      ask_yesno "Tentar outro caminho?" "y" || { echo "Pulando cópia do config."; CONFIG_SOURCE=""; break; }
    done
  else
    CONFIG_SOURCE=""
  fi
fi

JAR_NAME="$(ask_default 'Nome do JAR no destino (apenas nome do arquivo)' "$DEFAULT_JAR_NAME")"
CONFIG_NAME="$(ask_default 'Nome do config no destino (apenas nome do arquivo)' "$DEFAULT_CONFIG_NAME")"
JAVA_OPTS="$(ask_default 'JAVA_OPTS' "$DEFAULT_JAVA_OPTS")"

# utility: sha/cmp
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
    echo "Fazendo backup de $path -> $b"
    cp -p -- "$path" "$b"
  fi
}

# detect init
detect_init() {
  if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
    echo "systemd"
  elif [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  elif command -v initctl >/dev/null 2>&1; then
    echo "upstart"
  else
    echo "sysv"
  fi
}
INIT_SYSTEM="$(detect_init)"

# create group/user if missing
if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
  groupadd --system "$GROUP_NAME"
fi
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /sbin/nologin --gid "$GROUP_NAME" "$USER_NAME"
fi

# create install dir
mkdir -p "$INSTALL_DIR"
chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR"

DEST_JAR="${INSTALL_DIR%/}/${JAR_NAME}"
JAR_CHANGED=false
if file_differs "$JAR_SOURCE" "$DEST_JAR"; then
  cp -f -- "$JAR_SOURCE" "$DEST_JAR"
  chown "$USER_NAME:$GROUP_NAME" "$DEST_JAR"
  chmod 0550 "$DEST_JAR"
  JAR_CHANGED=true
else
  echo "JAR identico; nao sera copiado."
fi

CONFIG_CHANGED=false
if [[ -n "$CONFIG_SOURCE" ]]; then
  DEST_CONFIG="${INSTALL_DIR%/}/${CONFIG_NAME}"
  if file_differs "$CONFIG_SOURCE" "$DEST_CONFIG"; then
    cp -f -- "$CONFIG_SOURCE" "$DEST_CONFIG"
    chown "$USER_NAME:$GROUP_NAME" "$DEST_CONFIG"
    chmod 0640 "$DEST_CONFIG"
    CONFIG_CHANGED=true
  else
    echo "Config identico; nao sera copiado."
  fi
fi

# prepare /etc/default and unit (systemd)
ENV_FILE="/etc/default/${SERVICE_NAME}"
ENV_CONTENT="# /etc/default/${SERVICE_NAME}
JAVA_CMD=
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

RELOAD_DAEMON=false
if [[ "$INIT_SYSTEM" == "systemd" && ( "$UNIT_CHANGED" = true || "$ENV_CHANGED" = true ) ]]; then
  systemctl daemon-reload
  RELOAD_DAEMON=true
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
  echo "Sistema nao usa systemd; unidade criada mas nao gerenciada automaticamente."
fi

# --- JSON state management (per-install dir: <INSTALL_DIR>/.dfe-setup.json) ---
CFG_FILE="${INSTALL_DIR%/}/.dfe-setup.json"

# build record JSON (compact)
installedBy="${SUDO_USER:-$(whoami)}"
installedAt="$(timestamp)"
javapath="$(command -v java || echo '')"

record=$(jq -n \
  --arg serviceName "$SERVICE_NAME" \
  --arg jarName "$JAR_NAME" \
  --arg configName "$CONFIG_NAME" \
  --arg javaPath "$javapath" \
  --arg installDir "$INSTALL_DIR" \
  --arg installedAt "$installedAt" \
  --arg installedBy "$installedBy" \
  --arg os "linux" \
  '{serviceName:$serviceName, jarName:$jarName, configName:$configName, javaPath:$javaPath, logsEnabled:false, installDir:$installDir, installedAt:$installedAt, installedBy:$installedBy, os:$os }')

# Add or update using jq
if [[ -f "$CFG_FILE" ]]; then
  tmpf=$(mktemp)
  jq --argjson rec "$record" \
    '
    .installations |= ( ( . // [] ) as $inst
      | ( $inst
          | map( if (.serviceName == $rec.serviceName or .jarName == $rec.jarName) then $rec else . end )
        ) as $mapped
      | if ($mapped | length) == ($inst | length) then ($inst + [$rec]) else $mapped end
    )
    ' "$CFG_FILE" > "$tmpf" && mv "$tmpf" "$CFG_FILE"
else
  printf '{"installations":[%s]}\n' "$record" > "$CFG_FILE"
fi

echo
echo "Resumo:"
echo " Service: ${SERVICE_NAME}"
echo " Install dir: ${INSTALL_DIR}"
echo " JAR changed: ${JAR_CHANGED}"
echo " Config changed: ${CONFIG_CHANGED}"
echo " Unit created/changed: ${UNIT_CHANGED}"
echo " Env changed: ${ENV_CHANGED}"
echo " JSON state: ${CFG_FILE}"
echo
echo "Concluido."
exit 0
