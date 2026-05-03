#!/usr/bin/env bash
# dfe-setup.sh - Menu interativo (Linux)
# Versao: 1.1.0
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_VERSION="1.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE="${DFESCRIPTS_RAW_BASE:-https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts}"

# Diretório temporário para scripts baixados da rede.
# Usar nomes previsíveis (não mktemp por arquivo) garante que _state.sh
# fique no mesmo SCRIPT_DIR que os scripts que fazem source dele.
TMP_SCRIPTS="$(mktemp -d /tmp/dfe-scripts.XXXXXX)"
trap 'rm -rf "$TMP_SCRIPTS"' EXIT

BOOTSTRAP_NAME="dfe-bootstrap.sh"
INSTALL_SCRIPT_NAME="dfe-install.sh"
UNINSTALL_SCRIPT_NAME="dfe-uninstall.sh"
UPDATE_SCRIPT_NAME="dfe-update.sh"

TRACKER_API_URL="${TRACKER_API_URL:-}"
DFE_AMBIENTE="${DFE_AMBIENTE:-QA}"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

show_banner() {
  clear
  echo ""
  echo "=========================================================="
  echo "                                                          "
  echo "           DF-e Converter - Setup (Linux)                "
  echo "                                                          "
  echo "                   Versao: $SCRIPT_VERSION                "
  echo "                                                          "
  echo "              J2R Consultoria Informatica                 "
  echo "                                                          "
  echo "=========================================================="
  echo ""
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERRO: execute como root (sudo)"
    exit 1
  fi
}

# Baixa um único arquivo para o destino informado.
_http_get() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    log "curl ou wget nao encontrado"
    return 1
  fi
}

# Baixa um script para $TMP_SCRIPTS/<nome> e garante que _state.sh também
# esteja disponível no mesmo diretório (dependência de todos os scripts).
download_script() {
  local name="$1"
  local dest="${TMP_SCRIPTS}/${name}"

  log "Baixando ${RAW_BASE}/${name}"
  if ! _http_get "${RAW_BASE}/${name}" "$dest"; then
    rm -f "$dest"
    return 1
  fi
  chmod +x "$dest"

  # _state.sh precisa estar no mesmo dir que os scripts que fazem `source` dele
  if [[ "$name" != "_state.sh" && ! -f "${TMP_SCRIPTS}/_state.sh" ]]; then
    log "Baixando ${RAW_BASE}/_state.sh (dependencia)"
    _http_get "${RAW_BASE}/_state.sh" "${TMP_SCRIPTS}/_state.sh" || \
      log "AVISO: nao foi possivel baixar _state.sh"
    chmod +x "${TMP_SCRIPTS}/_state.sh" 2>/dev/null || true
  fi

  echo "$dest"
}

# Retorna o caminho do script: local (SCRIPT_DIR) tem prioridade,
# depois cache TMP_SCRIPTS, por último baixa da rede.
get_script() {
  local name="$1"
  local local_path="${SCRIPT_DIR}/${name}"

  if [[ -f "$local_path" ]]; then
    log "Usando local: $local_path"
    echo "$local_path"
    return 0
  fi

  if [[ -f "${TMP_SCRIPTS}/${name}" ]]; then
    echo "${TMP_SCRIPTS}/${name}"
    return 0
  fi

  download_script "$name"
}

run_bootstrap() {
  local path
  path="$(get_script "$BOOTSTRAP_NAME")"

  if [[ -z "$path" || ! -f "$path" ]]; then
    log "ERRO: bootstrap nao encontrado"
    return 1
  fi

  log "Executando bootstrap"
  bash "$path"
}

read_menu() {
  cat <<EOF

==========================================================
                    MENU PRINCIPAL
==========================================================

  1) Instalar service
  2) Remover service
  3) Reinstalar
  4) Status do service
  5) Verificar atualização
  6) Baixar e atualizar JAR
  7) Sair

EOF
  read -rp "Escolha (1-7): " choice
  echo "$choice"
}

do_install() {
  local path
  path="$(get_script "$INSTALL_SCRIPT_NAME")"

  if [[ -z "$path" || ! -f "$path" ]]; then
    log "ERRO: instalador nao encontrado"
    return 1
  fi

  log "Executando instalador"
  bash "$path"
}

do_uninstall() {
  local path
  path="$(get_script "$UNINSTALL_SCRIPT_NAME")"

  if [[ -z "$path" || ! -f "$path" ]]; then
    log "ERRO: desinstalador nao encontrado"
    return 1
  fi

  log "Executando desinstalador"
  bash "$path"
}

do_status() {
  echo ""
  read -rp "Nome do service: " service_name

  if [[ -z "$service_name" ]]; then
    echo "Nome vazio"
    return
  fi

  echo ""
  echo "=========================================================="
  echo "              STATUS DO SERVICO"
  echo "=========================================================="
  echo ""

  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "${service_name}.service" || echo "Service nao encontrado"
  else
    echo "systemctl nao disponivel"
  fi
}

do_check_update() {
  if [[ -z "$TRACKER_API_URL" ]]; then
    echo ""
    echo "ATENÇÃO: TRACKER_API_URL não definida."
    echo "  Defina com: export TRACKER_API_URL=https://tracker.seudominio.com"
    echo "  Ou execute: TRACKER_API_URL=https://... sudo ./dfe-setup.sh"
    return 1
  fi
  local path
  path="$(get_script "$UPDATE_SCRIPT_NAME")"
  if [[ -z "$path" || ! -f "$path" ]]; then
    log "ERRO: dfe-update.sh não encontrado"
    return 1
  fi
  TRACKER_API_URL="$TRACKER_API_URL" DFE_AMBIENTE_ARG="$DFE_AMBIENTE" \
    bash "$path" --api-url "$TRACKER_API_URL" --ambiente "$DFE_AMBIENTE"
  return $?
}

do_update() {
  if [[ -z "$TRACKER_API_URL" ]]; then
    echo ""
    echo "ATENÇÃO: TRACKER_API_URL não definida."
    echo "  Defina com: export TRACKER_API_URL=https://tracker.seudominio.com"
    return 1
  fi
  local path
  path="$(get_script "$UPDATE_SCRIPT_NAME")"
  if [[ -z "$path" || ! -f "$path" ]]; then
    log "ERRO: dfe-update.sh não encontrado"
    return 1
  fi
  bash "$path" --api-url "$TRACKER_API_URL" --ambiente "$DFE_AMBIENTE" --yes
  return $?
}

ensure_root
show_banner

log "Inicializando..."
echo ""

# Bootstrap is optional - do NOT exit on failure
if ! run_bootstrap 2>/dev/null; then
  echo ""
  echo "AVISO: Verificação de dependências encontrou alertas (veja acima)."
  echo "       A instalação pode continuar normalmente."
  echo ""
fi
log "Pronto."

while true; do
  opt="$(read_menu)"
  case "$opt" in
    1)
      do_install
      ;;
    2)
      do_uninstall
      ;;
    3)
      echo ""
      log "REINSTALACAO"
      log "Passo 1/2: Removendo..."
      do_uninstall || true
      echo ""
      log "Passo 2/2: Instalando..."
      do_install
      ;;
    4)
      do_status
      ;;
    5)
      do_check_update || true
      ;;
    6)
      do_update || true
      ;;
    7)
      echo ""
      log "Encerrando"
      exit 0
      ;;
    *)
      echo "Opcao invalida"
      ;;
  esac

  echo ""
  echo "----------------------------------------------------------"
  read -rp "Pressione ENTER para continuar"
  show_banner
done
