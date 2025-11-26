#!/usr/bin/env bash
# dfe-setup.sh - Menu interativo (Linux) que garante dependências via dfe-bootstrap.sh
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BOOTSTRAP="$SCRIPT_DIR/dfe-bootstrap.sh"
INSTALL_SCRIPT="$SCRIPT_DIR/dfe-install.sh"
UNINSTALL_SCRIPT="$SCRIPT_DIR/dfe-uninstall.sh"

# se bootstrap não existe localmente, tenta baixar do repo (raw) para /tmp e executar
maybe_fetch_bootstrap() {
  if [[ -f "$BOOTSTRAP" ]]; then
    return 0
  fi
  echo "Aviso: $BOOTSTRAP não encontrado localmente. Tentando baixar do GitHub (raw)..."
  RAW_BASE="https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/main/scripts"
  url="$RAW_BASE/$(basename "$BOOTSTRAP")"
  tmp="/tmp/$(basename "$BOOTSTRAP").$$"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$url" -o "$tmp"; then
      chmod +x "$tmp"
      echo "Bootstrap baixado temporariamente em $tmp"
      BOOTSTRAP="$tmp"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO "$tmp" "$url"; then
      chmod +x "$tmp"
      echo "Bootstrap baixado temporariamente em $tmp"
      BOOTSTRAP="$tmp"
      return 0
    fi
  fi
  echo "Falha ao obter dfe-bootstrap.sh. Instale jq manualmente e coloque dfe-bootstrap.sh no mesmo diretório."
  return 1
}

run_bootstrap() {
  # passa --yes se AUTO_INSTALL_JQ=1 foi fornecido no ambiente
  if [[ "${AUTO_INSTALL_JQ:-}" == "1" ]]; then
    "$BOOTSTRAP" --yes || { echo "Falha ao instalar dependencias (bootstrap). Abortando."; exit 1; }
  else
    "$BOOTSTRAP" || { echo "Bootstrap reportou problema. Abortando."; exit 1; }
  fi
}

menu() {
  cat <<EOF

=== DFe Converter Setup (Linux) ===

1) Instalar serviço
2) Remover serviço
3) Reinstalar (remove -> install)
4) Mostrar status do serviço
5) Sair

Escolha uma opcao (1-5):
EOF
  read -r opt
  echo "$opt"
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Este script precisa ser executado como root (sudo)."
    exit 1
  fi
}

do_install() {
  if [[ ! -x "$INSTALL_SCRIPT" ]]; then
    echo "Instalador não encontrado ou não executável: $INSTALL_SCRIPT"
    return 1
  fi
  bash "$INSTALL_SCRIPT"
}

do_uninstall() {
  if [[ ! -x "$UNINSTALL_SCRIPT" ]]; then
    echo "Uninstaller não encontrado ou não executável: $UNINSTALL_SCRIPT"
    return 1
  fi
  bash "$UNINSTALL_SCRIPT"
}

do_reinstall() {
  do_uninstall || true
  do_install
}

do_status() {
  read -rp "Nome do service (ex: dfe-converter-qa): " svc
  if [[ -z "$svc" ]]; then
    echo "Nome do service vazio. Abortando."
    return
  fi
  systemctl status "${svc}.service" --no-pager || true
}

# Main
ensure_root

if ! maybe_fetch_bootstrap; then
  echo "Bootstrap indisponível e download falhou. Instale jq manualmente e coloque dfe-bootstrap.sh no diretório $SCRIPT_DIR"
  exit 1
fi

echo "Verificando dependências (jq) via dfe-bootstrap..."
run_bootstrap

while true; do
  opt=$(menu)
  case "$opt" in
    1) do_install; break;;
    2) do_uninstall; break;;
    3) do_reinstall; break;;
    4) do_status; break;;
    5) echo "Saindo."; exit 0;;
    *) echo "Opcao invalida.";;
  esac
done
