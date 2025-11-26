#!/usr/bin/env bash
# dfe-setup.sh - Menu interativo (Linux)
# Versao: 1.0.0
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_VERSION="1.0. 0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE="${DFESCRIPTS_RAW_BASE:-https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts}"

BOOTSTRAP_NAME="dfe-bootstrap.sh"
INSTALL_SCRIPT_NAME="dfe-install.sh"
UNINSTALL_SCRIPT_NAME="dfe-uninstall.sh"

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

download_script() {
  local name="$1"
  local url="${RAW_BASE}/${name}"
  local dest
  dest="$(mktemp /tmp/${name}.XXXXXX)"

  log "Baixando $url"
  if command -v curl >/dev/null 2>&1; then
    if !  curl -fsSL "$url" -o "$dest"; then
      rm -f "$dest"
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$dest" "$url"; then
      rm -f "$dest"
      return 1
    fi
  else
    log "curl ou wget nao encontrado"
    rm -f "$dest"
    return 1
  fi

  chmod +x "$dest"
  echo "$dest"
}

get_script() {
  local name="$1"
  local local_path="${SCRIPT_DIR}/${name}"

  if [[ -f "$local_path" ]]; then
    log "Usando local: $local_path"
    echo "$local_path"
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
  if [[ "${AUTO_INSTALL_JQ:-}" == "1" ]]; then
    bash "$path" --yes
  else
    bash "$path"
  fi

  local ret=$?
  if [[ "$path" == /tmp/* ]]; then
    rm -f "$path"
  fi
  return $ret
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
  5) Sair

EOF
  read -rp "Escolha (1-5): " choice
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

  if [[ "$path" == /tmp/* ]]; then
    rm -f "$path"
  fi
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

  if [[ "$path" == /tmp/* ]]; then
    rm -f "$path"
  fi
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
    systemctl status "${service_name}. service" || echo "Service nao encontrado"
  else
    echo "systemctl nao disponivel"
  fi
}

ensure_root
show_banner

log "Inicializando..."
echo ""

if !  run_bootstrap; then
  log "ERRO: Bootstrap falhou"
  exit 1
fi

log "Bootstrap OK"

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
