#!/usr/bin/env bash
#
# install-dfe-converter-idempotent.sh
# Instala/configura um serviço systemd para um JAR, com comportamento idempotente e sem instalar nada novo no sistema.
# Principais características:
# - Usa seus defaults como valores padrão (dfeconv, /opt/DFE_CONVERTER_QA, etc.)
# - Só cria usuário/grupo se não existirem
# - Em re-runs valida checksums e conteúdo antes de copiar/substituir
# - Faz backup de unit /etc/default se forem alterados
# - Não instala pacotes; assume utilitários básicos (sh, systemctl, sha256sum/readlink, cp, mkdir, useradd/groupadd) disponíveis
#
# Uso:
#   sudo ./install-dfe-converter-idempotent.sh            # interativo
#   sudo ./install-dfe-converter-idempotent.sh --yes     # aceita defaults (não pergunta)
#   sudo ./install-dfe-converter-idempotent.sh --jar-source /caminho/meu.jar --config-source /caminho/config.properties
#   --no-start : não iniciar/ativar serviço no final
#   --force    : sobrescrever unit /etc/default sem perguntar
#
set -o errexit
set -o nounset
set -o pipefail

# Defaults (do seu exemplo)
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

timestamp() { date +%Y%m%d%H%M%S; }

print_help() {
  cat <<EOF
Uso: sudo $0 [--yes] [--jar-source PATH] [--config-source PATH] [--no-start] [--force] [-h]

--yes            Aceita todos os defaults sem perguntas
--jar-source     Caminho para o JAR de origem (obrigatório se não houver JAR no dir atual)
--config-source  Caminho para config.properties (opcional)
--no-start       Não iniciar/ativar o serviço após instalar
--force          Sobrescrever unit /etc/default sem perguntar
-h, --help       Mostra essa ajuda
EOF
}

# Simple arg parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) AUTO_YES=true; shift;;
    --jar-source) JAR_SOURCE="$2"; shift 2;;
    --config-source) CONFIG_SOURCE="$2"; shift 2;;
    --no-start) NO_START=true; shift;;
    --force) FORCE=true; shift;;
    -h|--help) print_help; exit 0;;
    *) echo "Opção desconhecida: $1"; print_help; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: execute este script como root (sudo)."
  exit 1
fi

ask_default() {
  # ask_default "Pergunta" "DEFAULT" -> prints chosen value
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
  # ask_yesno "Pergunta" default(y/n) -> returns 0 for yes, 1 for no
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

echo "=== Instalação do serviço para JAR (idempotente) ==="

SERVICE_NAME="$(ask_default 'Nome do serviço (systemd unit)' "$DEFAULT_SERVICE")"
# normalize: remove .service suffix if provided
SERVICE_NAME="${SERVICE_NAME%.service}"
USER_NAME="$(ask_default 'Usuário do sistema para rodar o serviço' "$DEFAULT_USER")"
GROUP_NAME="$USER_NAME"
INSTALL_DIR="$(ask_default 'Diretório de instalação' "$DEFAULT_INSTALL_DIR")"

# JAR source: required
if [[ -n "$JAR_SOURCE" ]]; then
  echo "Usando JAR informado via CLI: $JAR_SOURCE"
else
  # if there's a jar file in current dir with default name, propose it
  if [[ -f "./$DEFAULT_JAR_NAME" ]]; then
    JAR_SOURCE="$(ask_default 'Caminho para o JAR de origem' "./$DEFAULT_JAR_NAME")"
  else
    while true; do
      JAR_SOURCE="$(ask_default 'Caminho para o JAR de origem (obrigatório)' "./$DEFAULT_JAR_NAME")"
      if [[ -f "$JAR_SOURCE" ]]; then
        break
      fi
      echo "Arquivo JAR não encontrado: $JAR_SOURCE"
      ask_yesno "Tentar outro caminho?" "y" || { echo "Abortando: JAR é obrigatório."; exit 1; }
    done
  fi
fi

# Config source: optional
if [[ -n "$CONFIG_SOURCE" ]]; then
  echo "Usando config informado via CLI: $CONFIG_SOURCE"
else
  if ask_yesno "Você possui um config.properties para copiar?" "y"; then
    while true; do
      CONFIG_SOURCE="$(ask_default 'Caminho para o config (ou ENTER para pular)' "./$DEFAULT_CONFIG_NAME")"
      if [[ -z "$CONFIG_SOURCE" ]]; then
        CONFIG_SOURCE=""
        break
      fi
      if [[ -f "$CONFIG_SOURCE" ]]; then
        break
      fi
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

# Utility functions
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
  # file_differs src dst -> return 0 if differs or dst missing, 1 if equal
  local src="$1" dst="$2"
  if [[ ! -f "$dst" ]]; then
    return 0
  fi
  local s_sum d_sum
  s_sum="$(sha256_of_file "$src" || true)"
  d_sum="$(sha256_of_file "$dst" || true)"
  if [[ -n "$s_sum" && -n "$d_sum" ]]; then
    [[ "$s_sum" != "$d_sum" ]] && return 0 || return 1
  else
    # fallback: compare bytes
    if command -v cmp >/dev/null 2>&1; then
      ! cmp -s "$src" "$dst"
      return $?
    fi
    # no reliable comparator; assume differs to be safe
    return 0
  fi
}

backup_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    local b="${path}.bak.$(timestamp)"
    echo "Fazendo backup de $path -> $b"
    cp -p -- "$path" "$b"
  fi
}

# Detect init system (simple)
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
echo "Init system detectado: $INIT_SYSTEM"

# Ensure group exists (only if missing)
if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
  echo "Grupo $GROUP_NAME não existe: criando (system group)..."
  groupadd --system "$GROUP_NAME"
else
  echo "Grupo $GROUP_NAME já existe."
fi

# Ensure user exists (only if missing)
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  echo "Usuário $USER_NAME não existe: criando (system user, nologin)..."
  useradd --system --no-create-home --shell /sbin/nologin --gid "$GROUP_NAME" "$USER_NAME"
else
  echo "Usuário $USER_NAME já existe."
fi

# Create install dir if missing; if exists, ensure owner/perm are correct
if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Criando diretório $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
fi
chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR"

# Copy JAR if missing or differs
DEST_JAR="${INSTALL_DIR%/}/${JAR_NAME}"
JAR_CHANGED=false
if file_differs "$JAR_SOURCE" "$DEST_JAR"; then
  echo "Instalando JAR -> $DEST_JAR"
  cp -f -- "$JAR_SOURCE" "$DEST_JAR"
  chown "$USER_NAME:$GROUP_NAME" "$DEST_JAR"
  chmod 0550 "$DEST_JAR"
  JAR_CHANGED=true
else
  echo "JAR no destino é idêntico ao de origem; não será copiado."
fi

# Copy config if provided and differs
CONFIG_CHANGED=false
if [[ -n "$CONFIG_SOURCE" ]]; then
  DEST_CONFIG="${INSTALL_DIR%/}/${CONFIG_NAME}"
  if file_differs "$CONFIG_SOURCE" "$DEST_CONFIG"; then
    echo "Instalando config -> $DEST_CONFIG"
    cp -f -- "$CONFIG_SOURCE" "$DEST_CONFIG"
    chown "$USER_NAME:$GROUP_NAME" "$DEST_CONFIG"
    chmod 0640 "$DEST_CONFIG"
    CONFIG_CHANGED=true
  else
    echo "Config no destino é idêntico; não será copiado."
  fi
fi

# Prepare /etc/default env file content
ENV_FILE="/etc/default/${SERVICE_NAME}"
ENV_CONTENT="# /etc/default/${SERVICE_NAME}
# JAVA_CMD: caminho absoluto para java (ex: /usr/lib/jvm/jre/bin/java). Se vazio, usa 'java' do PATH.
JAVA_CMD=
JAVA_OPTS=\"${JAVA_OPTS}\"
EXTRA_OPTS=\"\"
"

# If ENV_FILE exists and content differs, back it up and optionally overwrite
ENV_CHANGED=false
if [[ -f "$ENV_FILE" ]]; then
  # compare existing to desired content
  if ! printf "%s" "$ENV_CONTENT" | cmp -s - "$ENV_FILE"; then
    echo "Arquivo de ambiente $ENV_FILE difere do template."
    if [[ "$FORCE" = true ]]; then
      backup_if_exists "$ENV_FILE"
      printf "%s" "$ENV_CONTENT" > "$ENV_FILE"
      chmod 0644 "$ENV_FILE"
      ENV_CHANGED=true
      echo "Arquivo $ENV_FILE sobrescrito (--force)."
    else
      if ask_yesno "Sobrescrever /etc/default/${SERVICE_NAME} com valores padrão?" "n"; then
        backup_if_exists "$ENV_FILE"
        printf "%s" "$ENV_CONTENT" > "$ENV_FILE"
        chmod 0644 "$ENV_FILE"
        ENV_CHANGED=true
        echo "Arquivo $ENV_FILE sobrescrito."
      else
        echo "Mantendo arquivo $ENV_FILE existente."
      fi
    fi
  else
    echo "/etc/default/${SERVICE_NAME} já está atualizado."
  fi
else
  echo "Criando /etc/default/${SERVICE_NAME}"
  printf "%s" "$ENV_CONTENT" > "$ENV_FILE"
  chmod 0644 "$ENV_FILE"
  ENV_CHANGED=true
fi

# Build systemd unit content (if systemd)
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

UNIT_CHANGED=false
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  if [[ -f "$UNIT_PATH" ]]; then
    # compare
    if ! printf "%s" "$UNIT_CONTENT" | cmp -s - "$UNIT_PATH"; then
      echo "Unit $UNIT_PATH difere do template."
      if [[ "$FORCE" = true ]]; then
        backup_if_exists "$UNIT_PATH"
        printf "%s" "$UNIT_CONTENT" > "$UNIT_PATH"
        chmod 0644 "$UNIT_PATH"
        UNIT_CHANGED=true
        echo "Unit sobrescrita (--force)."
      else
        if ask_yesno "Sobrescrever unit systemd $UNIT_PATH?" "n"; then
          backup_if_exists "$UNIT_PATH"
          printf "%s" "$UNIT_CONTENT" > "$UNIT_PATH"
          chmod 0644 "$UNIT_PATH"
          UNIT_CHANGED=true
          echo "Unit sobrescrita."
        else
          echo "Mantendo unit existente."
        fi
      fi
    else
      echo "Unit systemd já está atualizada."
    fi
  else
    echo "Criando unit systemd em $UNIT_PATH"
    printf "%s" "$UNIT_CONTENT" > "$UNIT_PATH"
    chmod 0644 "$UNIT_PATH"
    UNIT_CHANGED=true
  fi
fi

# If systemd unit changed or env changed -> daemon-reload
RELOAD_DAEMON=false
if [[ "$INIT_SYSTEM" == "systemd" && ( "$UNIT_CHANGED" = true || "$ENV_CHANGED" = true ) ]]; then
  echo "Recarregando systemd daemon..."
  systemctl daemon-reload
  RELOAD_DAEMON=true
fi

# Decide whether to restart the service:
# - If service is active and any of JAR_CHANGED/CONFIG_CHANGED/UNIT_CHANGED/ENV_CHANGED then restart
# - If service inactive and not NO_START then start
SERVICE_ACTIVE=false
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    SERVICE_ACTIVE=true
  fi
fi

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  if $SERVICE_ACTIVE; then
    if [[ "$JAR_CHANGED" = true || "$CONFIG_CHANGED" = true || "$UNIT_CHANGED" = true || "$ENV_CHANGED" = true ]]; then
      echo "Mudanças detectadas e serviço está ativo -> reiniciando ${SERVICE_NAME}..."
      systemctl restart "${SERVICE_NAME}.service" || echo "Aviso: falha ao reiniciar o serviço. Veja journalctl -u ${SERVICE_NAME}"
    else
      echo "Nenhuma mudança relevante detectada; não será reiniciado."
    fi
  else
    if ! $NO_START; then
      echo "Serviço não está ativo -> iniciando e habilitando ${SERVICE_NAME}..."
      systemctl enable --now "${SERVICE_NAME}.service" || echo "Aviso: falha ao iniciar/habilitar; verifique logs."
    else
      echo "Serviço não iniciado por opção (--no-start). Para iniciar: systemctl start ${SERVICE_NAME}.service"
    fi
  fi
else
  echo "Sistema não usa systemd (detected: ${INIT_SYSTEM}). Este script cria arquivos e copia artefatos, mas não gerencia serviços para esse init system automaticamente."
  echo "Se precisar de suporte a upstart/sysv, avise e eu adapto o script."
fi

echo
echo "=== Resumo da execução ==="
echo "Service: ${SERVICE_NAME}"
echo "User: ${USER_NAME}"
echo "Install dir: ${INSTALL_DIR}"
echo "JAR installed/changed: ${JAR_CHANGED}"
echo "Config installed/changed: ${CONFIG_CHANGED}"
echo "Env file created/changed: ${ENV_CHANGED}"
echo "Unit created/changed: ${UNIT_CHANGED}"
echo "systemd daemon-reload executed: ${RELOAD_DAEMON}"
echo
echo "Comandos úteis:"
echo "  journalctl -u ${SERVICE_NAME} -f"
echo "  systemctl status ${SERVICE_NAME}"
echo "  cat /etc/default/${SERVICE_NAME}"
echo "  cat /etc/systemd/system/${SERVICE_NAME}.service"
echo
echo "Fim."
