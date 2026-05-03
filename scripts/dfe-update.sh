#!/usr/bin/env bash
# dfe-update.sh - Verifica e aplica atualização do DF-e Converter
# Consulta o tracker-main API e atualiza o JAR sem intervenção manual.
# Requer: curl ou wget, sha256sum ou shasum
set -o nounset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_state.sh
source "${SCRIPT_DIR}/_state.sh"

# Configurações — podem ser sobrescritas por variável de ambiente
TRACKER_API_URL="${TRACKER_API_URL:-}"
DFE_AMBIENTE_ARG="${DFE_AMBIENTE_ARG:-}"
STATE_FILE_ARG="${DFE_STATE_FILE_ARG:-}"
AUTO_YES=false

log()  { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s AVISO: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
err()  { printf '%s ERRO: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

print_help() {
  cat <<EOF
Uso: sudo $0 --api-url URL [--state-file PATH] [--ambiente QA|PROD] [--yes] [-h]

--api-url     URL base do tracker-main (ex: https://tracker.seudominio.com)
--state-file  Caminho para .dfe-setup.env (padrão: detecta pelo install-dir)
--install-dir Diretório de instalação (alternativa ao --state-file)
--ambiente    QA ou PROD (padrão: lê do estado instalado)
--yes         Confirma atualização sem perguntar
-h, --help    Exibe esta ajuda
EOF
}

INSTALL_DIR_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url)     TRACKER_API_URL="$2"; shift 2;;
    --state-file)  STATE_FILE_ARG="$2"; shift 2;;
    --install-dir) INSTALL_DIR_ARG="$2"; shift 2;;
    --ambiente)    DFE_AMBIENTE_ARG="${2^^}"; shift 2;;
    --yes|-y)      AUTO_YES=true; shift;;
    -h|--help)     print_help; exit 0;;
    *)             err "Opção desconhecida: $1"; print_help; exit 1;;
  esac
done

# Validate required args
if [[ -z "$TRACKER_API_URL" ]]; then
  err "URL do tracker-main é obrigatória. Use --api-url URL"
  exit 1
fi
TRACKER_API_URL="${TRACKER_API_URL%/}"  # remove trailing slash

# Find state file
find_state_file() {
  if [[ -n "$STATE_FILE_ARG" ]]; then
    echo "$STATE_FILE_ARG"
  elif [[ -n "$INSTALL_DIR_ARG" ]]; then
    echo "${INSTALL_DIR_ARG%/}/.dfe-setup.env"
  else
    # Try common locations
    for dir in /opt/DFE_CONVERTER_QA /opt/DFE_CONVERTER_PROD /opt/dfe-converter; do
      if [[ -f "${dir}/.dfe-setup.env" ]]; then
        echo "${dir}/.dfe-setup.env"
        return 0
      fi
    done
    echo ""
  fi
}

STATE_FILE="$(find_state_file)"
if [[ -z "$STATE_FILE" || ! -f "$STATE_FILE" ]]; then
  err "Arquivo de estado não encontrado. Use --state-file ou --install-dir."
  exit 1
fi

log "Estado: $STATE_FILE"

# Load current state
CURRENT_VERSAO="$(_state_read DFE_VERSAO "$STATE_FILE")"
CURRENT_CHECKSUM="$(_state_read DFE_CHECKSUM_SHA256 "$STATE_FILE")"
INSTALL_DIR="$(_state_read DFE_INSTALL_DIR "$STATE_FILE")"
SERVICE_NAME="$(_state_read DFE_SERVICE_NAME "$STATE_FILE")"
JAR_NAME="$(_state_read DFE_JAR_NAME "$STATE_FILE")"
AMBIENTE="${DFE_AMBIENTE_ARG:-$(_state_read DFE_AMBIENTE "$STATE_FILE")}"
AMBIENTE="${AMBIENTE:-QA}"

log "Instalação detectada: service=$SERVICE_NAME | versão=$CURRENT_VERSAO | ambiente=$AMBIENTE"

# HTTP helper using curl or wget
http_get() {
  local url="$1" output_file="${2:-}"
  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$output_file" ]]; then
      curl -fsSL "$url" -o "$output_file"
    else
      curl -fsSL "$url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [[ -n "$output_file" ]]; then
      wget -qO "$output_file" "$url"
    else
      wget -qO- "$url"
    fi
  else
    err "curl ou wget não encontrado"
    return 1
  fi
}

# Fetch latest version info from tracker-main
INFO_URL="${TRACKER_API_URL}/api/v1/dfe-converter/versoes/latest/info?ambiente=${AMBIENTE}&tipo=JAR"
log "Consultando versão disponível: $INFO_URL"

INFO_TEXT="$(http_get "$INFO_URL" 2>/dev/null || echo "")"
if [[ -z "$INFO_TEXT" ]]; then
  err "Não foi possível obter informações de versão. Verifique a URL e conectividade."
  exit 1
fi

# Parse the key=value response (no jq needed)
parse_info_value() {
  local key="$1"
  echo "$INFO_TEXT" | grep "^${key}=" | cut -d'=' -f2-
}

REMOTE_VERSAO="$(parse_info_value DFE_VERSAO)"
REMOTE_CHECKSUM="$(parse_info_value DFE_CHECKSUM_SHA256)"
REMOTE_NOME="$(parse_info_value DFE_NOME_ARQUIVO)"
REMOTE_TAMANHO="$(parse_info_value DFE_TAMANHO_BYTES)"
REMOTE_DATA="$(parse_info_value DFE_DATA_UPLOAD)"

if [[ -z "$REMOTE_VERSAO" ]]; then
  err "Resposta inválida do servidor. Versão não encontrada na resposta."
  exit 1
fi

log "Versão remota: $REMOTE_VERSAO | Versão instalada: ${CURRENT_VERSAO:-nenhuma}"

# Compare versions
if [[ "$REMOTE_VERSAO" == "$CURRENT_VERSAO" && -n "$CURRENT_VERSAO" ]]; then
  # Also compare checksum for extra safety
  if [[ "$REMOTE_CHECKSUM" == "$CURRENT_CHECKSUM" && -n "$CURRENT_CHECKSUM" ]]; then
    log "Já está na versão mais recente ($REMOTE_VERSAO). Nenhuma atualização necessária."
    exit 0
  fi
fi

# Show update info
echo ""
echo "=========================================================="
echo "              ATUALIZAÇÃO DISPONÍVEL"
echo "=========================================================="
echo ""
printf "  %-20s %s\n" "Versão instalada:"  "${CURRENT_VERSAO:-nenhuma}"
printf "  %-20s %s\n" "Versão disponível:" "$REMOTE_VERSAO"
printf "  %-20s %s\n" "Arquivo:"           "${REMOTE_NOME:-DFe-Converter-${AMBIENTE}.jar}"
printf "  %-20s %s\n" "Tamanho:"           "$(( ${REMOTE_TAMANHO:-0} / 1048576 )) MB"
printf "  %-20s %s\n" "Data upload:"       "${REMOTE_DATA:-N/A}"
echo ""

if ! $AUTO_YES; then
  read -rp "Deseja atualizar? (y/N): " yn
  case "${yn,,}" in
    y|yes) ;;
    *) log "Atualização cancelada pelo usuário."; exit 0;;
  esac
fi

# Download new JAR
DOWNLOAD_URL="${TRACKER_API_URL}/api/v1/dfe-converter/versoes/latest/download?ambiente=${AMBIENTE}&tipo=JAR"
TMP_JAR="$(mktemp /tmp/dfe-converter-XXXXXX.jar)"
log "Baixando: $DOWNLOAD_URL"

if ! http_get "$DOWNLOAD_URL" "$TMP_JAR"; then
  rm -f "$TMP_JAR"
  err "Falha ao baixar o arquivo."
  exit 1
fi

# Validate checksum
if [[ -n "$REMOTE_CHECKSUM" ]]; then
  log "Validando checksum SHA-256..."
  DOWNLOADED_CHECKSUM=""
  if command -v sha256sum >/dev/null 2>&1; then
    DOWNLOADED_CHECKSUM="$(sha256sum "$TMP_JAR" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    DOWNLOADED_CHECKSUM="$(shasum -a 256 "$TMP_JAR" | awk '{print $1}')"
  fi

  if [[ -n "$DOWNLOADED_CHECKSUM" ]]; then
    if [[ "$DOWNLOADED_CHECKSUM" != "$REMOTE_CHECKSUM" ]]; then
      rm -f "$TMP_JAR"
      err "Checksum inválido! Esperado: $REMOTE_CHECKSUM | Obtido: $DOWNLOADED_CHECKSUM"
      exit 1
    fi
    log "Checksum OK: $DOWNLOADED_CHECKSUM"
  else
    warn "Verificação de checksum ignorada (sha256sum/shasum não disponível)."
  fi
fi

# Apply update
DEST_JAR="${INSTALL_DIR%/}/${JAR_NAME}"

# Stop service
log "Parando service: $SERVICE_NAME"
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop "${SERVICE_NAME}.service" || warn "Falha ao parar o service (pode não estar rodando)."
fi

# Backup current JAR
if [[ -f "$DEST_JAR" ]]; then
  BAK="${DEST_JAR}.bak.$(date +%s)"
  log "Backup: $DEST_JAR -> $BAK"
  cp -p -- "$DEST_JAR" "$BAK"
fi

# Replace JAR
log "Substituindo JAR em: $DEST_JAR"
mv -f "$TMP_JAR" "$DEST_JAR"
chown "$(stat -c '%U:%G' "$INSTALL_DIR")" "$DEST_JAR" 2>/dev/null || true
chmod 0550 "$DEST_JAR"

# Restart service
log "Iniciando service: $SERVICE_NAME"
if command -v systemctl >/dev/null 2>&1; then
  systemctl start "${SERVICE_NAME}.service" || warn "Falha ao iniciar o service."
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    log "Service iniciado com sucesso."
  else
    warn "Service pode não ter iniciado corretamente. Verifique: systemctl status ${SERVICE_NAME}"
  fi
fi

# Update state
_state_write DFE_VERSAO          "$REMOTE_VERSAO"  "$STATE_FILE"
_state_write DFE_CHECKSUM_SHA256 "$REMOTE_CHECKSUM" "$STATE_FILE"
_state_write DFE_INSTALLED_AT    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$STATE_FILE"

log "Atualização concluída: ${CURRENT_VERSAO:-nenhuma} -> $REMOTE_VERSAO"
exit 0
