#!/usr/bin/env bash
# dfe-uninstall.sh - Desinstalador para systemd (remove unit/env e atualiza <INSTALL_DIR>/.dfe-setup.json)
# Requer: jq
set -o errexit
set -o nounset
set -o pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (sudo)."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  cat >&2 <<'ERR'
ERRO: este script usa 'jq' para manipular JSON.
Instale jq primeiro. Exemplos:
  Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y jq
  RHEL/CentOS: sudo dnf install -y jq
ERR
  exit 1
fi

print_help() {
  cat <<EOF
Uso: sudo $0 [--service NAME] [--install-dir PATH]

--service NAME     Nome do systemd service a remover (ex: dfe-converter-qa)
--install-dir PATH Diretório da instalação (ex: /opt/DFE_CONVERTER_QA). Se informado, removemos entry nesse .dfe-setup.json
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
  select opt in "DFeConverterQA" "DFeConverterPROD" "Outro"; do
    case "$opt" in
      "DFeConverterQA") SERVICE_NAME="DFeConverterQA"; break;;
      "DFeConverterPROD") SERVICE_NAME="DFeConverterPROD"; break;;
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

# Update .dfe-setup.json in provided INSTALL_DIR (if provided)
if [[ -n "$INSTALL_DIR" ]]; then
  CFG_FILE="${INSTALL_DIR%/}/.dfe-setup.json"
  if [[ -f "$CFG_FILE" ]]; then
    tmpf=$(mktemp)
    # Filter out installations with matching serviceName
    jq --arg svc "$SERVICE_NAME" ' if (.installations|length) > 0 then .installations |= [ .installations[] | select(.serviceName != $svc) ] else . end | if (.installations|length) == 0 then empty else . end' "$CFG_FILE" > "$tmpf" || true
    if [[ -s "$tmpf" ]]; then
      mv "$tmpf" "$CFG_FILE"
      echo "Registro removido do JSON em $CFG_FILE"
    else
      rm -f "$CFG_FILE"
      echo "Nenhuma instalacao remanescente; arquivo JSON removido."
    fi
  else
    echo "Arquivo de estado nao encontrado em: $CFG_FILE"
  fi
else
  echo "Nenhum --install-dir informado; nao atualizei .dfe-setup.json"
fi

echo "Desinstalacao concluida (verifique Services/systemctl)."
exit 0
