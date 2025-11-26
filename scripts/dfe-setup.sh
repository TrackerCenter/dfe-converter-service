#!/usr/bin/env bash
# dfe-setup.sh - Menu interativo para instalar / remover / reinstalar (Linux)
# Baixa scripts do GitHub ou usa locais e executa bootstrap antes de prosseguir.
# Execute como root (sudo).
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE="${DFESCRIPTS_RAW_BASE:-https://raw. githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts}"

BOOTSTRAP_NAME="dfe-bootstrap.sh"
INSTALL_SCRIPT_NAME="dfe-install.sh"
UNINSTALL_SCRIPT_NAME="dfe-uninstall.sh"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERRO: execute este script como root (sudo)."
    exit 1
  fi
}

download_script_to_temp() {
  local name="$1"
  local url="${RAW_BASE}/${name}"
  local dest
  dest="$(mktemp /tmp/"${name}. XXXXXX")"

  log "Baixando $url -> $dest"
  if command -v curl >/dev/null 2>&1; then
    if !  curl -fsSL "$url" -o "$dest"; then
      rm -f "$dest"
      log "Falha ao baixar via curl: $url"
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$dest" "$url"; then
      rm -f "$dest"
      log "Falha ao baixar via wget: $url"
      return 1
    fi
  else
    log "Nem curl nem wget disponíveis."
    rm -f "$dest"
    return 1
  fi

  chmod +x "$dest"
  echo "$dest"
}

get_script_path() {
  local name="$1"
  local local_path="${SCRIPT_DIR}/${name}"

  if [[ -f "$local_path" ]]; then
    log "Usando script local: $local_path"
    echo "$local_path"
    return 0
  fi

  log "Script local não encontrado, tentando baixar: $name"
  download_script_to_temp "$name"
}

run_bootstrap() {
  local bootstrap_path
  bootstrap_path="$(get_script_path "$BOOTSTRAP_NAME")"

  if [[ -z "$bootstrap_path" || ! -f "$bootstrap_path" ]]; then
    log "ERRO: Não foi possível obter $BOOTSTRAP_NAME"
    return 1
  fi

  log "Executando bootstrap: $bootstrap_path"
  if [[ "${AUTO_INSTALL_JQ:-}" == "1" ]]; then
    bash "$bootstrap_path" --yes
  else
    bash "$bootstrap_path"
  fi

  local ret=$?

  # Cleanup se foi temporário
  if [[ "$bootstrap_path" == /tmp/* ]]; then
    rm -f "$bootstrap_path"
  fi

  return $ret
}

read_menu() {
  cat <<EOF

=== DFe Converter Setup (Linux) ===
1) Instalar service
2) Remover service
3) Reinstalar (remove -> install)
4) Status do service
5) Sair
EOF
  read -rp "Escolha (1-5): " choice
  echo "$choice"
}

do_install() {
  local install_path
  install_path="$(get_script_path "$INSTALL_SCRIPT_NAME")"

  if [[ -z "$install_path" || !  -f "$install_path" ]]; then
    log "ERRO: Não foi possível obter $INSTALL_SCRIPT_NAME"
    return 1
  fi

  log "Executando instalador: $install_path"
  bash "$install_path"

  # Cleanup se foi temporário
  if [[ "$install_path" == /tmp/* ]]; then
    rm -f "$install_path"
  fi
}

do_uninstall() {
  local uninstall_path
  uninstall_path="$(get_script_path "$UNINSTALL_SCRIPT_NAME")"

  if [[ -z "$uninstall_path" || ! -f "$uninstall_path" ]]; then
    log "ERRO: Não foi possível obter $UNINSTALL_SCRIPT_NAME"
    return 1
  fi

  log "Executando desinstalador: $uninstall_path"
  bash "$uninstall_path"

  # Cleanup se foi temporário
  if [[ "$uninstall_path" == /tmp/* ]]; then
    rm -f "$uninstall_path"
  fi
}

do_status() {
  echo ""
  echo "Digite o nome do service para checar (ex: dfe-converter-qa):"
  read -r service_name

  if [[ -z "$service_name" ]]; then
    echo "Nome vazio, cancelando."
    return
  fi

  echo ""
  echo "=== Status do Service: $service_name ==="

  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "${service_name}. service" || echo "Service não encontrado ou erro."
  else
    echo "systemctl não disponível neste sistema."
  fi
}

# ================== Entrypoint ===================
ensure_root

log "=== DFe Converter Setup (Linux) ==="
log "Inicializando..."

# Executa bootstrap primeiro para garantir dependências (jq)
if !  run_bootstrap; then
  log "ERRO: Bootstrap falhou. Instale as dependências manualmente e tente novamente."
  exit 1
fi

log "Bootstrap concluído com sucesso."

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
      log "Reinstalação: removendo service existente..."
      do_uninstall || true
      log "Agora instalando novamente..."
      do_install
      ;;
    4)
      do_status
      ;;
    5)
      log "Saindo."
      exit 0
      ;;
    *)
      echo "Opção inválida."
      ;;
  esac

  echo ""
  read -rp "Pressione ENTER para continuar"
done
