#!/usr/bin/env bash
# dfe-bootstrap.sh - Verifica e instala dependências necessárias (atualmente: jq)
# Uso:
#   ./dfe-bootstrap.sh         # interativo (pergunta antes de instalar)
#   AUTO_INSTALL_JQ=1 ./dfe-bootstrap.sh   # instala sem perguntar
#   ./dfe-bootstrap.sh --yes   # instala sem perguntar
set -o errexit
set -o nounset
set -o pipefail

AUTO_CONFIRM=0
if [[ "${AUTO_INSTALL_JQ:-}" == "1" ]]; then AUTO_CONFIRM=1; fi
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then AUTO_CONFIRM=1; fi

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    log "jq já instalado: $(command -v jq)"
    return 0
  fi

  log "jq não encontrado. Vou tentar instalar."

  # detect package manager
  PM=""
  if command -v apt-get >/dev/null 2>&1; then PM="apt"; fi
  if command -v dnf >/dev/null 2>&1; then PM="dnf"; fi
  if command -v yum >/dev/null 2>&1 && [[ -z "$PM" ]]; then PM="yum"; fi
  if command -v apk >/dev/null 2>&1; then PM="apk"; fi
  if command -v pacman >/dev/null 2>&1; then PM="pacman"; fi
  if command -v zypper >/dev/null 2>&1; then PM="zypper"; fi

  if [[ $AUTO_CONFIRM -ne 1 ]]; then
    echo
    read -r -p "Deseja que eu instale 'jq' automaticamente? (y/N): " yn
    case "${yn,,}" in
      y|yes) ;;
      *) echo "Instalação de jq cancelada. Instale jq manualmente e reexecute."; return 1;;
    esac
  else
    log "Instalação automática autorizada (AUTO_INSTALL_JQ=1 ou --yes)."
  fi

  # helper to run commands as root
  run_as_root() {
    if [[ $EUID -eq 0 ]]; then
      bash -c "$*"
      return $?
    elif command -v sudo >/dev/null 2>&1; then
      sudo bash -c "$*"
      return $?
    else
      return 2
    fi
  }

  case "$PM" in
    apt)
      log "Detectado apt (Debian/Ubuntu). Tentando apt-get update && apt-get install -y jq"
      if run_as_root "apt-get update -y && apt-get install -y jq"; then
        command -v jq >/dev/null 2>&1 && { log "jq instalado via apt"; return 0; }
      fi
      log "Falha apt ou jq não disponível via apt."
      ;;
    dnf)
      log "Detectado dnf (Fedora/RHEL8+). Tentando dnf install -y jq"
      if run_as_root "dnf install -y jq"; then
        command -v jq >/dev/null 2>&1 && { log "jq instalado via dnf"; return 0; }
      fi
      log "Falha dnf ou jq não disponível via dnf."
      ;;
    yum)
      log "Detectado yum (RHEL/CentOS). Tentando instalar EPEL e jq"
      if run_as_root "yum install -y epel-release || true; yum install -y jq"; then
        command -v jq >/dev/null 2>&1 && { log "jq instalado via yum"; return 0; }
      fi
      log "Falha yum ou jq não disponível via yum."
      ;;
    apk)
      log "Detectado apk (Alpine). Tentando apk add --no-cache jq"
      if run_as_root "apk add --no-cache jq"; then
        command -v jq >/dev/null 2>&1 && { log "jq instalado via apk"; return 0; }
      fi
      log "Falha apk ou jq não disponível via apk."
      ;;
    pacman)
      log "Detectado pacman (Arch). Tentando pacman -Syu --noconfirm jq"
      if run_as_root "pacman -Syu --noconfirm jq"; then
        command -v jq >/dev/null 2>&1 && { log "jq instalado via pacman"; return 0; }
      fi
      log "Falha pacman ou jq não disponível via pacman."
      ;;
    zypper)
      log "Detectado zypper (openSUSE). Tentando zypper install -y jq"
      if run_as_root "zypper install -y jq"; then
        command -v jq >/dev/null 2>&1 && { log "jq instalado via zypper"; return 0; }
      fi
      log "Falha zypper ou jq não disponível via zypper."
      ;;
    *)
      log "Nenhum package manager suportado detectado. Irei tentar baixar binário oficial."
      ;;
  esac

  # Fallback: baixar binário
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) jq_bin="jq-linux64";;
    i386|i686) jq_bin="jq-linux32";;
    aarch64|arm64) jq_bin="jq-linux64";; # tentamos linux64; recomenda-se usar package manager para ARM
    *) jq_bin="jq-linux64";;
  esac
  jq_url="https://github.com/stedolan/jq/releases/download/jq-1.6/${jq_bin}"
  log "Baixando $jq_url"

  tmpf="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$jq_url" -o "$tmpf"; then rm -f "$tmpf"; log "Falha no download via curl"; return 1; fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$tmpf" "$jq_url"; then rm -f "$tmpf"; log "Falha no download via wget"; return 1; fi
  else
    log "Nem curl nem wget disponíveis para baixar jq. Instale um deles ou instale jq manualmente."
    return 1
  fi

  # tenta mover para /usr/local/bin se possível
  if run_as_root "mv '$tmpf' /usr/local/bin/jq && chmod 0755 /usr/local/bin/jq"; then
    command -v jq >/dev/null 2>&1 && { log "jq instalado em /usr/local/bin/jq"; return 0; }
    log "mv para /usr/local/bin teve sucesso mas jq não ficou disponível no PATH."
  else
    # fallback local
    user_dest="$HOME/.local/bin/jq"
    mkdir -p "$(dirname "$user_dest")"
    if mv "$tmpf" "$user_dest" 2>/dev/null; then
      chmod 0755 "$user_dest"
      export PATH="$HOME/.local/bin:$PATH"
      command -v jq >/dev/null 2>&1 && { log "jq instalado localmente em $user_dest"; return 0; }
      log "jq colocado em $user_dest, verifique PATH."
    else
      rm -f "$tmpf"
      log "Falha ao mover jq localmente."
    fi
  fi

  log "Falha ao instalar jq automaticamente. Instale manualmente e reexecute."
  return 1
}

# entrypoint
if ensure_jq; then
  log "Dependências OK."
  exit 0
else
  log "Dependências não resolvidas."
  exit 1
fi