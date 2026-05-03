#!/usr/bin/env bash
# _state.sh - Funções para leitura/escrita do arquivo de estado .dfe-setup.env
# Não requer jq, python ou qualquer ferramenta externa.
# Formato do arquivo: KEY=VALUE (uma por linha)
# Inclua este arquivo com: source "$(dirname "${BASH_SOURCE[0]}")/_state.sh"

# Lê o valor de uma chave no arquivo de estado.
# Retorna string vazia se chave não encontrada ou arquivo não existe.
# Uso: _state_read KEY [ARQUIVO]
_state_read() {
  local key="$1"
  local file="${2:-${DFE_STATE_FILE:-}}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# Escreve/atualiza uma chave no arquivo de estado.
# Se a chave já existe, atualiza o valor. Se não existe, adiciona.
# Uso: _state_write KEY VALUE [ARQUIVO]
_state_write() {
  local key="$1"
  local value="$2"
  local file="${3:-${DFE_STATE_FILE:-}}"
  if [[ -z "$file" ]]; then
    echo "ERRO: _state_write: arquivo não especificado" >&2
    return 1
  fi
  # Cria arquivo se não existir
  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # Atualiza linha existente (usa | como separador para evitar conflito com / em paths)
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# Inicializa/cria um arquivo de estado vazio com comentário.
# Uso: _state_init ARQUIVO
_state_init() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '# DFe Converter - Estado da instalação\n# Gerado automaticamente em %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$file"
  fi
}

# Carrega variáveis do arquivo de estado para o shell atual.
# Apenas variáveis DFE_* são carregadas (seguro contra injeção).
# Uso: _state_load [ARQUIVO]
_state_load() {
  local file="${1:-${DFE_STATE_FILE:-}}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    return 0
  fi
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      DFE_*) export "${key}=${value}";;
    esac
  done < <(grep '^DFE_' "$file" 2>/dev/null)
}

# Verifica se uma instalação existe (arquivo de estado presente e com SERVICE_NAME).
# Retorna 0 (true) se existe, 1 (false) se não.
# Uso: _state_exists [ARQUIVO]
_state_exists() {
  local file="${1:-${DFE_STATE_FILE:-}}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    return 1
  fi
  local svc
  svc="$(_state_read DFE_SERVICE_NAME "$file")"
  [[ -n "$svc" ]]
}

# Exibe o conteúdo do estado formatado para leitura.
# Uso: _state_show [ARQUIVO]
_state_show() {
  local file="${1:-${DFE_STATE_FILE:-}}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    echo "(nenhum estado encontrado)"
    return 0
  fi
  echo "--- Estado: $file ---"
  grep '^DFE_' "$file" 2>/dev/null || echo "(arquivo vazio ou sem entradas DFE_*)"
  echo "------"
}
