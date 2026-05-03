#!/usr/bin/env bash
# dfe-bootstrap.sh - Verifica dependências básicas (curl/wget).
# jq NÃO é mais necessário (estado gerenciado via .dfe-setup.env key=value).
set -o nounset

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

check_downloader() {
  if command -v curl >/dev/null 2>&1; then
    log "OK: curl encontrado ($(curl --version | head -1))"
    return 0
  elif command -v wget >/dev/null 2>&1; then
    log "OK: wget encontrado"
    return 0
  else
    log "ERRO: nem curl nem wget encontrados. Instale um deles para continuar."
    return 1
  fi
}

check_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    log "OK: sha256sum encontrado"
  elif command -v shasum >/dev/null 2>&1; then
    log "OK: shasum encontrado"
  else
    log "AVISO: nenhuma ferramenta sha256 encontrada. Validação de checksum será ignorada."
  fi
}

check_systemctl() {
  if command -v systemctl >/dev/null 2>&1; then
    log "OK: systemctl encontrado"
  else
    log "AVISO: systemctl não encontrado. Gerenciamento de service pode ser limitado."
  fi
}

# jq é opcional agora - somente aviso, não falha
check_jq_optional() {
  if command -v jq >/dev/null 2>&1; then
    log "INFO: jq encontrado (não necessário, mas disponível)"
  else
    log "INFO: jq não encontrado (não é necessário para esta versão dos scripts)"
  fi
}

main() {
  log "Verificando dependências..."
  check_downloader || exit 1
  check_sha256
  check_systemctl
  check_jq_optional
  log "Dependências OK."
  exit 0
}

main