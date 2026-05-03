#!/usr/bin/env bash
# dfe-uninstall.sh - Desinstalador para systemd (remove unit/env e limpa <INSTALL_DIR>/.dfe-setup.env)
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_state.sh
source "${SCRIPT_DIR}/_state.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (sudo)."
  exit 1
fi

print_help() {
  cat <<EOF
Uso: sudo $0 [--service NAME] [--install-dir PATH]

--service NAME     Nome do systemd service a remover (ex: dfe-converter-qa)
--install-dir PATH Diretório da instalação (ex: /opt/DFE_CONVERTER_QA). Se informado, remove .dfe-setup.env
-h, --help         Mostra essa ajuda
EOF
}

SERVICE_NAME=""
INSTALL_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE_NAME="$2"; shift 2;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    -h|--help) print_help; exit 0;;
    *) echo "Opção desconhecida: $1"; print_help; exit 1;;
  esac
done

if [[ -z "$SERVICE_NAME" ]]; then
  echo "Escolha o servico para desinstalar:"
  select opt in "dfe-converter-qa" "dfe-converter-prod" "Outro"; do
    case "$opt" in
      "dfe-converter-qa") SERVICE_NAME="dfe-converter-qa"; break;;
      "dfe-converter-prod") SERVICE_NAME="dfe-converter-prod"; break;;
      "Outro") read -rp "Digite o nome exato do servico: " SERVICE_NAME; break;;
    esac
  done
fi

echo "Confirmar desinstalacao do servico '$SERVICE_NAME'? (y/N)"
read -r confirm
if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
  echo "Cancelado."
  exit 0
fi

# stop and remove systemd unit
set +e
if systemctl status "${SERVICE_NAME}.service" >/dev/null 2>&1; then
  systemctl stop "${SERVICE_NAME}.service" || true
  systemctl disable "${SERVICE_NAME}.service" || true
fi
set -e

UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="/etc/default/${SERVICE_NAME}"

if [[ -f "$UNIT_PATH" ]]; then
  cp -a "$UNIT_PATH" "${UNIT_PATH}.bak.$(date +%s)"
  rm -f "$UNIT_PATH"
  echo "Unit $UNIT_PATH removida."
fi
if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
  rm -f "$ENV_FILE"
  echo "Env $ENV_FILE removido."
fi
systemctl daemon-reload || true

# Remove .dfe-setup.env in provided INSTALL_DIR (if provided)
if [[ -n "$INSTALL_DIR" ]]; then
  CFG_FILE="${INSTALL_DIR%/}/.dfe-setup.env"
  if [[ -f "$CFG_FILE" ]]; then
    rm -f "$CFG_FILE"
    echo "Arquivo de estado removido: $CFG_FILE"
  else
    echo "Arquivo de estado não encontrado em: $CFG_FILE"
  fi
else
  echo "Nenhum --install-dir informado; arquivo de estado não removido."
fi

echo "Desinstalacao concluida (verifique Services/systemctl)."
exit 0
