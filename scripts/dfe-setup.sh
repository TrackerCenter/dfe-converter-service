#!/usr/bin/env bash
# dfe-setup.sh - Menu interativo (Linux)
# Versao: 1.9.0
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_VERSION="1.9.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RAW_BASE: quando servido pelo tracker-main, __TRACKER_BASE_URL__ é substituído
# automaticamente pela URL do servidor. Fallback para GitHub se executado localmente.
RAW_BASE="${DFESCRIPTS_RAW_BASE:-__TRACKER_BASE_URL__/api/v1/dfe-converter/versoes/setup/scripts/linux}"

# Diretório temporário para scripts baixados da rede.
# Usar nomes previsíveis (não mktemp por arquivo) garante que _state.sh
# fique no mesmo SCRIPT_DIR que os scripts que fazem source dele.
TMP_SCRIPTS="$(mktemp -d /tmp/dfe-scripts.XXXXXX)"
trap 'rm -rf "$TMP_SCRIPTS"' EXIT

BOOTSTRAP_NAME="dfe-bootstrap.sh"
INSTALL_SCRIPT_NAME="dfe-install.sh"
UNINSTALL_SCRIPT_NAME="dfe-uninstall.sh"
UPDATE_SCRIPT_NAME="dfe-update.sh"

DFE_AUTOUPDATE_SCRIPT="/usr/local/bin/dfe-autoupdate"
DFE_AUTOUPDATE_LOG="/var/log/dfe-autoupdate.log"
DFE_AUTOUPDATE_TAG="# dfe-autoupdate-managed"

TRACKER_API_URL="${TRACKER_API_URL:-}"
DFE_AMBIENTE="${DFE_AMBIENTE:-}"

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
# Toda saída vai para stderr para não contaminar capturas via $().
_http_get() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    log "curl ou wget nao encontrado" >&2
    return 1
  fi
}

# Retorna o conteúdo de uma URL no stdout.
_http_get_text() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    log "curl ou wget nao encontrado" >&2
    return 1
  fi
}

# Baixa um arquivo grande com barra de progresso visível no terminal.
_http_get_large() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress -O "$dest" "$url" 2>&1
  else
    log "curl ou wget nao encontrado" >&2
    return 1
  fi
}

# Solicita ao usuário qual servidor do Tracker usar para buscar scripts e executáveis.
# Define TRACKER_API_URL globalmente para toda a sessão.
# Não faz nada se TRACKER_API_URL já estiver definida.
# NOTA: a URL do servidor é independente do ambiente do executável (QA/PROD).
ensure_api_url() {
  if [[ -n "$TRACKER_API_URL" ]]; then
    return 0
  fi

  echo ""
  echo "=========================================================="
  echo "         SELECIONAR SERVIDOR DO TRACKER"
  echo "=========================================================="
  echo ""
  echo "  Define de onde baixar os scripts e executaveis."
  echo "  Ambos os servidores contem executaveis de QA e PROD."
  echo ""
  echo "  1) QA   - https://qa.trackercenter.com.br/app (mais recente)"
  echo "  2) PROD - https://prod.trackercenter.com.br/app (estavel)"
  echo "  3) URL personalizada"
  echo ""

  local choice
  while true; do
    read -rp "Escolha (1-3): " choice
    case "$choice" in
      1) TRACKER_API_URL="https://qa.trackercenter.com.br/app"; break;;
      2) TRACKER_API_URL="https://prod.trackercenter.com.br/app"; break;;
      3)
        local custom_url
        read -rp "URL base do Tracker (ex: https://tracker.seudominio.com/app): " custom_url
        TRACKER_API_URL="${custom_url%/}"
        break
        ;;
      *) echo "Opcao invalida. Escolha 1, 2 ou 3.";;
    esac
  done

  echo ""
  log "Servidor: $TRACKER_API_URL"
}

# Solicita ao usuário qual versão do executável DFe Converter instalar/atualizar.
# Imprime QA ou PROD no stdout; mensagens de prompt vão para stderr.
# Independente da URL do servidor selecionada em ensure_api_url().
_select_dfe_ambiente() {
  echo "" >&2
  echo "==========================================================" >&2
  echo "     VERSAO DO DFe CONVERTER A INSTALAR/ATUALIZAR" >&2
  echo "==========================================================" >&2
  echo "" >&2
  echo "  1) QA   - DFe-Converter-QA.jar  (homologacao/testes)" >&2
  echo "  2) PROD - DFe-Converter-PROD.jar (producao)" >&2
  echo "" >&2
  local choice
  while true; do
    read -rp "Escolha (1-2): " choice
    case "$choice" in
      1) echo "QA";   return 0;;
      2) echo "PROD"; return 0;;
      *) echo "Opcao invalida. Escolha 1 ou 2." >&2;;
    esac
  done
}

# Baixa um script para $TMP_SCRIPTS/<nome> e garante que _state.sh também
# esteja disponível no mesmo diretório (dependência de todos os scripts).
# Apenas o caminho final é impresso no stdout; logs vão para stderr.
download_script() {
  local name="$1"
  local dest="${TMP_SCRIPTS}/${name}"

  log "Baixando ${RAW_BASE}/${name}" >&2
  if ! _http_get "${RAW_BASE}/${name}" "$dest"; then
    rm -f "$dest"
    return 1
  fi
  chmod +x "$dest"

  # _state.sh precisa estar no mesmo dir que os scripts que fazem `source` dele
  if [[ "$name" != "_state.sh" && ! -f "${TMP_SCRIPTS}/_state.sh" ]]; then
    log "Baixando ${RAW_BASE}/_state.sh (dependencia)" >&2
    _http_get "${RAW_BASE}/_state.sh" "${TMP_SCRIPTS}/_state.sh" || \
      log "AVISO: nao foi possivel baixar _state.sh" >&2
    chmod +x "${TMP_SCRIPTS}/_state.sh" 2>/dev/null || true
  fi

  echo "$dest"
}

# Retorna o caminho do script: local (SCRIPT_DIR) tem prioridade,
# depois cache TMP_SCRIPTS, por último baixa da rede.
# Apenas o caminho é impresso no stdout; logs vão para stderr.
get_script() {
  local name="$1"
  local local_path="${SCRIPT_DIR}/${name}"

  if [[ -f "$local_path" ]]; then
    log "Usando local: $local_path" >&2
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

show_menu() {
  cat >&2 <<EOF

==========================================================
                    MENU PRINCIPAL
==========================================================

  1) Instalar service
  2) Remover service
  3) Reinstalar
  4) Status do service
  5) Listar serviços dfe instalados
  6) Verificar atualização
  7) Baixar e atualizar JAR
  8) Configurar auto-update
  9) Sair

EOF
}

do_list_services() {
  echo ""
  echo "=========================================================="
  echo "           SERVIÇOS dfe-* INSTALADOS"
  echo "=========================================================="
  echo ""
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl não disponível"
    return
  fi

  # Lista todos os units dfe-* carregados (ativos ou não)
  local found
  found="$(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null \
    | grep -i 'dfe-' || true)"

  if [[ -z "$found" ]]; then
    echo "  Nenhum serviço dfe-* encontrado."
  else
    printf "  %-40s %-12s %-10s %s\n" "SERVIÇO" "STATUS" "ATIVO" "DESCRIÇÃO"
    echo "  -----------------------------------------------------------------------"
    while IFS= read -r line; do
      printf "  %s\n" "$line"
    done <<< "$found"
  fi
  echo ""
}

do_install() {
  ensure_api_url || return 1

  # 0. Selecionar qual executável instalar (QA ou PROD) — independente do servidor
  local install_ambiente
  install_ambiente="$(_select_dfe_ambiente)"

  # 1. Buscar metadados e mostrar versão disponível
  log "Consultando versao disponivel ($install_ambiente)..."
  local info_text
  info_text="$(_http_get_text "${TRACKER_API_URL}/api/v1/dfe-converter/versoes/latest/info?ambiente=${install_ambiente}&tipo=JAR" 2>/dev/null || echo "")"

  if [[ -z "$info_text" ]]; then
    log "ERRO: nao foi possivel obter informacoes de versao. Verifique a URL e conectividade."
    return 1
  fi

  local remote_versao remote_nome remote_tamanho remote_data
  remote_versao="$(echo "$info_text" | grep '^DFE_VERSAO='        | cut -d'=' -f2-)"
  remote_nome="$(echo    "$info_text" | grep '^DFE_NOME_ARQUIVO='  | cut -d'=' -f2-)"
  remote_tamanho="$(echo "$info_text" | grep '^DFE_TAMANHO_BYTES=' | cut -d'=' -f2-)"
  remote_data="$(echo    "$info_text" | grep '^DFE_DATA_UPLOAD='   | cut -d'=' -f2-)"
  remote_nome="${remote_nome:-DFe-Converter-${install_ambiente}.jar}"

  echo ""
  echo "=========================================================="
  echo "         VERSAO DISPONIVEL PARA INSTALACAO"
  echo "=========================================================="
  echo ""
  printf "  Ambiente : %s\n"   "$install_ambiente"
  printf "  Versao   : %s\n"   "${remote_versao:-?}"
  printf "  Arquivo  : %s\n"   "$remote_nome"
  printf "  Tamanho  : %s MB\n" "$(( ${remote_tamanho:-0} / 1048576 ))"
  printf "  Data     : %s\n"   "${remote_data:-?}"
  echo ""
  local yn
  read -rp "Prosseguir com a instalacao? [S/n]: " yn
  case "${yn,,}" in
    ''|s|y|yes|sim) ;;
    *) log "Instalacao cancelada."; return 0;;
  esac

  # 2. Coletar config.properties interativamente
  echo ""
  echo "=========================================================="
  echo "      CONFIGURACAO DO DFe CONVERTER"
  echo "=========================================================="
  echo ""
  echo "  Pressione ENTER para aceitar o valor padrao."
  echo ""

  local cfg_tenant
  read -rp "  sync.tenant (identificador do cliente, obrigatorio): " cfg_tenant
  if [[ -z "$cfg_tenant" ]]; then
    log "ERRO: sync.tenant e obrigatorio."
    return 1
  fi

  local cfg_port cfg_interval
  read -rp "  sync.port [9393]: " cfg_port;              cfg_port="${cfg_port:-9393}"
  read -rp "  sync.intervaloMinutos [15]: " cfg_interval; cfg_interval="${cfg_interval:-15}"

  echo ""
  echo "  Pastas (separe multiplos caminhos com ;)"
  echo ""
  local cfg_pasta_sync cfg_pasta_conv cfg_pasta_proc cfg_pasta_rel
  read -rp "  Pasta de entrada (sincronizacao) [/dados/xmls]: " cfg_pasta_sync
  cfg_pasta_sync="${cfg_pasta_sync:-/dados/xmls}"
  read -rp "  Pasta de saida (convertido) [/dados/saida]: " cfg_pasta_conv
  cfg_pasta_conv="${cfg_pasta_conv:-/dados/saida}"
  read -rp "  Pasta de processamento [/dados/processado]: " cfg_pasta_proc
  cfg_pasta_proc="${cfg_pasta_proc:-/dados/processado}"
  read -rp "  Pasta de relatorio [/dados/relatorio]: " cfg_pasta_rel
  cfg_pasta_rel="${cfg_pasta_rel:-/dados/relatorio}"

  local tmp_config
  tmp_config="$(mktemp /tmp/dfe-config-XXXXXX.properties)"
  cat > "$tmp_config" <<CONFIG_EOF
# Configuracao gerada pelo dfe-setup.sh em $(date)

sync.port=${cfg_port}
sync.intervaloMinutos=${cfg_interval}
sync.tamanhoLoteEnvio=2000
sync.tenant=${cfg_tenant}

sync.padraoSaidaTr=true
sync.ignorarTagsReformaTributaria=true
sync.proxySalvarArquivoOriginal=true
sync.proxySalvarArquivoConvertido=true
sync.proxyConfig=POST|/api/nfe|txt_conteudo.xml
sync.proxyBaseUrl=https://ws.h.dfe.mastersaf.com.br
sync.proxyEstrategiaErro=IGNORAR

internet.proxy.enabled=false
internet.proxy.host=proxy.example.com
internet.proxy.port=81

nfe.pastas.sincronizacao=${cfg_pasta_sync}
nfe.pasta.convertido=${cfg_pasta_conv}
nfe.pasta.processamento=${cfg_pasta_proc}
nfe.pasta.relatorio=${cfg_pasta_rel}
nfe.criarTagVNFTot=true

cte.pastas.sincronizacao=${cfg_pasta_sync}
cte.pasta.convertido=${cfg_pasta_conv}
cte.pasta.processamento=${cfg_pasta_proc}
cte.pasta.relatorio=${cfg_pasta_rel}

nfse.pastas.sincronizacao=${cfg_pasta_sync}
nfse.pasta.convertido=${cfg_pasta_conv}
nfse.pasta.processamento=${cfg_pasta_proc}
nfse.pasta.relatorio=${cfg_pasta_rel}
CONFIG_EOF

  # 3. Baixar instalador e JAR
  local path
  path="$(get_script "$INSTALL_SCRIPT_NAME")"
  if [[ -z "$path" || ! -f "$path" ]]; then
    rm -f "$tmp_config"
    log "ERRO: instalador nao encontrado"
    return 1
  fi

  local tmp_jar
  tmp_jar="$(mktemp /tmp/dfe-jar-XXXXXX.jar)"

  echo ""
  log "Baixando ${remote_nome} (${install_ambiente} v${remote_versao:-?})..."
  if ! _http_get_large "${TRACKER_API_URL}/api/v1/dfe-converter/versoes/latest/download?ambiente=${install_ambiente}&tipo=JAR" "$tmp_jar"; then
    rm -f "$tmp_jar" "$tmp_config"
    log "ERRO: falha ao baixar o JAR"
    return 1
  fi

  # 4. Executar instalador com --yes (defaults por ambiente) + config gerado
  echo ""
  log "Executando instalador..."
  bash "$path" \
    --jar-source "$tmp_jar" \
    --config-source "$tmp_config" \
    --ambiente "$install_ambiente" \
    --versao "${remote_versao:-}" \
    --yes
  local rc=$?
  rm -f "$tmp_jar" "$tmp_config"
  return $rc
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
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "  systemctl nao disponivel"
    return 0
  fi

  # Coletar serviços a partir dos state files das instalações conhecidas
  local -a services=()
  while IFS= read -r dir; do
    local svc
    svc="$(grep '^DFE_SERVICE_NAME=' "${dir}/.dfe-setup.env" 2>/dev/null | cut -d'=' -f2- || true)"
    svc="${svc%.service}"
    [[ -n "$svc" ]] && services+=("$svc")
  done < <(_find_dfe_installations)

  # Fallback: varrer systemctl por units dfe-*
  if [[ ${#services[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      local svc
      svc="$(printf '%s' "$line" | awk '{print $1}' | sed 's/\.service$//')"
      [[ -n "$svc" ]] && services+=("$svc")
    done < <(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null \
      | grep -i 'dfe-' || true)
  fi

  if [[ ${#services[@]} -eq 0 ]]; then
    echo ""
    echo "  Nenhum servico dfe-* encontrado."
    echo "  Use a opcao 1 (Instalar service) para instalar o DFe Converter."
    echo ""
    return 0
  fi

  # Selecionar serviço (pula seleção se apenas um)
  local service_name
  if [[ ${#services[@]} -eq 1 ]]; then
    service_name="${services[0]}"
  else
    echo ""
    echo "=========================================================="
    echo "              SELECIONAR SERVICO"
    echo "=========================================================="
    echo ""
    local i=1
    for svc in "${services[@]}"; do
      local state
      state="$(systemctl is-active "${svc}.service" 2>/dev/null || true)"
      printf "  %d) %-35s [%s]\n" "$i" "$svc" "${state:-desconhecido}"
      (( i++ ))
    done
    echo ""
    local choice
    read -rp "Escolha o servico (1-${#services[@]}): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#services[@]} )); then
      echo "Opcao invalida"
      return 0
    fi
    service_name="${services[$((choice - 1))]}"
  fi

  # Submenu de ações — permanece até o usuário escolher Voltar
  local _dummy
  while true; do
    local state
    state="$(systemctl is-active "${service_name}.service" 2>/dev/null || true)"

    echo ""
    echo "=========================================================="
    printf "   SERVICO: %-30s [%s]\n" "$service_name" "${state:-desconhecido}"
    echo "=========================================================="
    echo ""
    echo "  1) Ver detalhes"
    echo "  2) Reiniciar"
    if [[ "$state" == "active" ]]; then
      echo "  3) Parar"
    else
      echo "  3) Iniciar"
    fi
    echo "  4) Voltar"
    echo ""

    local action
    read -rp "Escolha (1-4): " action
    case "$action" in
      1)
        echo ""
        echo "=========================================================="
        echo "              STATUS DO SERVICO"
        echo "=========================================================="
        echo ""
        systemctl status "${service_name}.service" --no-pager -l 2>&1 || true
        echo ""
        read -rp "Pressione ENTER para continuar..." _dummy
        ;;
      2)
        echo ""
        log "Reiniciando ${service_name}..."
        if systemctl restart "${service_name}.service" 2>&1; then
          log "Servico reiniciado com sucesso."
        else
          log "AVISO: falha ao reiniciar. Use 'Ver detalhes' para diagnosticar."
        fi
        echo ""
        read -rp "Pressione ENTER para continuar..." _dummy
        ;;
      3)
        echo ""
        if [[ "$state" == "active" ]]; then
          log "Parando ${service_name}..."
          if systemctl stop "${service_name}.service" 2>&1; then
            log "Servico parado."
          else
            log "AVISO: falha ao parar o servico."
          fi
        else
          log "Iniciando ${service_name}..."
          if systemctl start "${service_name}.service" 2>&1; then
            log "Servico iniciado com sucesso."
          else
            log "AVISO: falha ao iniciar. Use 'Ver detalhes' para diagnosticar."
          fi
        fi
        echo ""
        read -rp "Pressione ENTER para continuar..." _dummy
        ;;
      4)
        return 0
        ;;
      *)
        echo "  Opcao invalida. Escolha 1, 2, 3 ou 4."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Detecção de instalações existentes
# ---------------------------------------------------------------------------

# Retorna (um por linha) os diretórios onde há uma instalação do DFe Converter.
# Verifica locais padrão + qualquer dir sob /opt com .dfe-setup.env.
_find_dfe_installations() {
  local -A seen=()
  # Locais padrão conhecidos
  for dir in /opt/DFE_CONVERTER_QA /opt/DFE_CONVERTER_PROD /opt/dfe-converter; do
    if [[ -f "${dir}/.dfe-setup.env" ]] && [[ -z "${seen[$dir]+x}" ]]; then
      seen[$dir]=1
      echo "$dir"
    fi
  done
  # Varredura geral em /opt (até 3 níveis)
  while IFS= read -r envfile; do
    local d
    d="$(dirname "$envfile")"
    if [[ -z "${seen[$d]+x}" ]]; then
      seen[$d]=1
      echo "$d"
    fi
  done < <(find /opt -maxdepth 3 -name ".dfe-setup.env" 2>/dev/null || true)
}

# Solicita ao usuário que selecione (ou informe) o diretório de instalação.
# Imprime o diretório escolhido no stdout; retorna 1 se o usuário cancelar.
_select_install_dir() {
  local installations=()
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && installations+=("$dir")
  done < <(_find_dfe_installations)

  if [[ ${#installations[@]} -eq 0 ]]; then
    echo "" >&2
    log "Nenhuma instalacao encontrada nos locais padrao (/opt)." >&2
    log "  Use a opcao 1 (Instalar service) para instalar o DFe Converter." >&2
    local custom_dir
    read -rp "Informe o diretorio com instalacao existente (vazio para cancelar): " custom_dir >&2
    if [[ -z "$custom_dir" ]]; then
      return 1
    fi
    if [[ ! -f "${custom_dir%/}/.dfe-setup.env" ]]; then
      echo "" >&2
      log "AVISO: '${custom_dir}' nao possui instalacao DFe (.dfe-setup.env nao encontrado)." >&2
      log "       Instale o DFe Converter primeiro (opcao 1 do menu)." >&2
      return 1
    fi
    echo "${custom_dir%/}"
    return 0
  fi

  if [[ ${#installations[@]} -eq 1 ]]; then
    log "Instalacao encontrada: ${installations[0]}" >&2
    echo "${installations[0]}"
    return 0
  fi

  # Múltiplas instalações — deixa o usuário escolher
  echo "" >&2
  echo "  Instalacoes encontradas:" >&2
  local i=1
  for dir in "${installations[@]}"; do
    local svc ver
    svc="$(grep '^DFE_SERVICE_NAME=' "${dir}/.dfe-setup.env" 2>/dev/null | cut -d'=' -f2- || true)"
    ver="$(grep  '^DFE_VERSAO='       "${dir}/.dfe-setup.env" 2>/dev/null | cut -d'=' -f2- || true)"
    printf "  %d) %-40s  service=%-25s  versao=%s\n" \
      "$i" "$dir" "${svc:-?}" "${ver:-?}" >&2
    ((i++))
  done
  echo "" >&2
  local choice
  read -rp "Escolha a instalacao (1-${#installations[@]}): " choice >&2
  local idx=$(( choice - 1 ))
  if [[ $idx -lt 0 || $idx -ge ${#installations[@]} ]]; then
    echo "Opcao invalida" >&2
    return 1
  fi
  echo "${installations[$idx]}"
}

do_check_update() {
  ensure_api_url || return 1

  # Listar todos os arquivos disponíveis na última versão (QA e PROD)
  echo ""
  echo "=========================================================="
  echo "       ARQUIVOS DISPONIVEIS NA ULTIMA VERSAO"
  echo "=========================================================="
  echo ""
  printf "  %-5s  %-5s  %-35s  %-10s  %8s  %s\n" "AMB" "TIPO" "NOME" "VERSAO" "TAMANHO" "DATA UPLOAD"
  echo "  -----------------------------------------------------------------------"
  for amb in QA PROD; do
    for tipo in JAR EXE; do
      local info_text
      info_text="$(_http_get_text "${TRACKER_API_URL}/api/v1/dfe-converter/versoes/latest/info?ambiente=${amb}&tipo=${tipo}" 2>/dev/null || echo "")"
      if [[ -n "$info_text" ]]; then
        local remote_versao remote_nome remote_tamanho remote_data
        remote_versao="$(echo "$info_text" | grep '^DFE_VERSAO='        | cut -d'=' -f2-)"
        remote_nome="$(echo   "$info_text" | grep '^DFE_NOME_ARQUIVO='  | cut -d'=' -f2-)"
        remote_tamanho="$(echo "$info_text" | grep '^DFE_TAMANHO_BYTES=' | cut -d'=' -f2-)"
        remote_data="$(echo   "$info_text" | grep '^DFE_DATA_UPLOAD='   | cut -d'=' -f2-)"
        printf "  %-5s  %-5s  %-35s  %-10s  %5s MB  %s\n" \
          "$amb" "$tipo" "${remote_nome:-?}" "${remote_versao:-?}" \
          "$(( ${remote_tamanho:-0} / 1048576 ))" "${remote_data:-?}"
      else
        printf "  %-5s  %-5s  (nao disponivel)\n" "$amb" "$tipo"
      fi
    done
  done
  echo ""

  # Detectar instalações existentes para verificar se há atualização pendente
  local install_dir
  install_dir="$(_select_install_dir)" || return 0

  local path
  path="$(get_script "$UPDATE_SCRIPT_NAME")"
  if [[ -z "$path" || ! -f "$path" ]]; then
    log "ERRO: dfe-update.sh nao encontrado"
    return 1
  fi

  # Ler ambiente da instalação existente (state file tem prioridade)
  local state_ambiente
  state_ambiente="$(grep '^DFE_AMBIENTE=' "${install_dir}/.dfe-setup.env" 2>/dev/null | cut -d'=' -f2- || echo "")"
  state_ambiente="${state_ambiente:-QA}"

  bash "$path" --api-url "$TRACKER_API_URL" --ambiente "$state_ambiente" --install-dir "$install_dir"
  return $?
}

do_update() {
  ensure_api_url || return 1

  local install_dir
  if ! install_dir="$(_select_install_dir)"; then
    echo ""
    log "Nenhuma instalacao valida encontrada."
    local yn
    read -rp "Deseja realizar a instalacao inicial agora? [S/n]: " yn
    case "${yn,,}" in
      ''|s|y|yes|sim) do_install; return $?;;
      *) return 0;;
    esac
  fi

  local path
  path="$(get_script "$UPDATE_SCRIPT_NAME")"
  if [[ -z "$path" || ! -f "$path" ]]; then
    log "ERRO: dfe-update.sh nao encontrado"
    return 1
  fi
  # Ler ambiente da instalação existente (state file tem prioridade)
  local state_ambiente
  state_ambiente="$(grep '^DFE_AMBIENTE=' "${install_dir}/.dfe-setup.env" 2>/dev/null | cut -d'=' -f2- || echo "")"
  state_ambiente="${state_ambiente:-QA}"

  bash "$path" --api-url "$TRACKER_API_URL" --ambiente "$state_ambiente" --install-dir "$install_dir" --yes
  return $?
}

# ---------------------------------------------------------------------------
# Auto-update via crontab
# ---------------------------------------------------------------------------

# Exibe o status atual do auto-update (cron entry + script configurado).
_show_autoupdate_status() {
  echo ""
  echo "=========================================================="
  echo "           STATUS DO AUTO-UPDATE"
  echo "=========================================================="
  echo ""
  local current_cron
  current_cron="$(crontab -l 2>/dev/null | grep "$DFE_AUTOUPDATE_TAG" || true)"
  if [[ -n "$current_cron" ]]; then
    local cron_expr
    cron_expr="$(echo "$current_cron" | sed "s|${DFE_AUTOUPDATE_SCRIPT}.*||" | xargs)"
    echo "  Status      : ATIVO"
    echo "  Agendamento : $cron_expr"
  else
    echo "  Status      : INATIVO"
  fi
  if [[ -f "$DFE_AUTOUPDATE_SCRIPT" ]]; then
    local configured_url configured_env
    configured_url="$(grep '^TRACKER_API_URL=' "$DFE_AUTOUPDATE_SCRIPT" 2>/dev/null \
      | cut -d'"' -f2 || true)"
    configured_env="$(grep '^DFE_AMBIENTE=' "$DFE_AUTOUPDATE_SCRIPT" 2>/dev/null \
      | cut -d'"' -f2 || true)"
    echo "  Script      : $DFE_AUTOUPDATE_SCRIPT"
    [[ -n "$configured_url" ]] && echo "  URL         : $configured_url"
    [[ -n "$configured_env" ]] && echo "  Ambiente    : $configured_env"
  fi
  echo "  Log         : $DFE_AUTOUPDATE_LOG"
  echo ""
}

# Gera o script wrapper /usr/local/bin/dfe-autoupdate com URL e ambiente fixos.
_write_autoupdate_script() {
  local gen_date
  gen_date="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$DFE_AUTOUPDATE_SCRIPT" <<AUTOUPDATE_EOF
#!/usr/bin/env bash
# Gerado automaticamente pelo dfe-setup.sh em ${gen_date}
# Ambiente: ${DFE_AMBIENTE} | URL: ${TRACKER_API_URL}
# Para reconfigurar execute: sudo dfe-setup (opcao 8)
TRACKER_API_URL="${TRACKER_API_URL}"
DFE_AMBIENTE="${DFE_AMBIENTE}"
UPDATE_URL="${RAW_BASE}/dfe-update.sh"

log_au() { printf '%s dfe-autoupdate %s\n' "\$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "\$*"; }

log_au "Iniciando verificacao automatica (ambiente=\${DFE_AMBIENTE})..."

tmpscript="\$(mktemp /tmp/dfe-update.XXXXXX.sh)"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "\${UPDATE_URL}" -o "\${tmpscript}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "\${tmpscript}" "\${UPDATE_URL}"
else
  log_au "ERRO: curl ou wget nao encontrado"
  exit 1
fi

chmod +x "\${tmpscript}"
bash "\${tmpscript}" --api-url "\${TRACKER_API_URL}" --ambiente "\${DFE_AMBIENTE}" --yes
rc=\$?
rm -f "\${tmpscript}"
log_au "Concluido (rc=\${rc})"
exit \${rc}
AUTOUPDATE_EOF
  chmod +x "$DFE_AUTOUPDATE_SCRIPT"
  log "Script gerado: $DFE_AUTOUPDATE_SCRIPT"
}

# Ativa o auto-update com a expressão cron informada.
_set_autoupdate_cron() {
  local cron_expr="$1" descr="$2"
  _write_autoupdate_script
  local cron_line="${cron_expr} ${DFE_AUTOUPDATE_SCRIPT} >> ${DFE_AUTOUPDATE_LOG} 2>&1 ${DFE_AUTOUPDATE_TAG}"
  local tmp_cron
  tmp_cron="$(mktemp)"
  { crontab -l 2>/dev/null | grep -v "$DFE_AUTOUPDATE_TAG"; echo "$cron_line"; } > "$tmp_cron"
  crontab "$tmp_cron"
  rm -f "$tmp_cron"
  echo ""
  log "Auto-update ATIVADO: $descr"
  echo "  Agendamento : $cron_expr"
  echo "  Script      : $DFE_AUTOUPDATE_SCRIPT"
  echo "  Log         : $DFE_AUTOUPDATE_LOG"
}

# Solicita uma expressão cron personalizada com exemplos.
_set_autoupdate_cron_custom() {
  echo ""
  echo "  Formato: minuto hora dia-do-mes mes dia-da-semana"
  echo ""
  echo "  Exemplos:"
  echo "    0 1 * * *    -> todos os dias as 01:00"
  echo "    0 1 * * 1    -> toda segunda-feira as 01:00"
  echo "    0 */6 * * *  -> a cada 6 horas"
  echo "    0 2 1 * *    -> todo dia 1 do mes as 02:00"
  echo "    30 3 * * 0,6 -> sabado e domingo as 03:30"
  echo ""
  local expr
  read -rp "Expressao cron (5 campos): " expr
  if [[ -z "$expr" ]]; then
    echo "Cancelado."
    return 0
  fi
  local field_count
  field_count="$(echo "$expr" | awk '{print NF}')"
  if [[ "$field_count" -ne 5 ]]; then
    echo "ERRO: expressao deve ter 5 campos (minuto hora dia mes dia-semana)"
    return 1
  fi
  _set_autoupdate_cron "$expr" "personalizado"
}

# Desativa o auto-update removendo a entrada do crontab.
_remove_autoupdate_cron() {
  local tmp_cron
  tmp_cron="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$DFE_AUTOUPDATE_TAG" > "$tmp_cron" || true
  crontab "$tmp_cron"
  rm -f "$tmp_cron"
  local remove_script
  read -rp "Remover tambem o script ${DFE_AUTOUPDATE_SCRIPT}? [s/N]: " remove_script
  if [[ "${remove_script,,}" == "s" ]]; then
    rm -f "$DFE_AUTOUPDATE_SCRIPT"
    log "Script removido"
  fi
  log "Auto-update DESATIVADO"
}

do_autoupdate() {
  ensure_api_url || return 1

  # DFE_AMBIENTE precisa estar definido para o script de auto-update
  if [[ -z "${DFE_AMBIENTE:-}" ]]; then
    DFE_AMBIENTE="$(_select_dfe_ambiente)"
  fi

  _show_autoupdate_status
  echo "  1) Ativar - Todo dia as 01:00"
  echo "  2) Ativar - Toda segunda-feira as 01:00"
  echo "  3) Ativar - Personalizado (expressao cron)"
  echo "  4) Desativar auto-update"
  echo "  5) Voltar"
  echo ""
  local choice
  read -rp "Escolha (1-5): " choice
  case "$choice" in
    1) _set_autoupdate_cron "0 1 * * *" "todo dia as 01:00";;
    2) _set_autoupdate_cron "0 1 * * 1" "toda segunda-feira as 01:00";;
    3) _set_autoupdate_cron_custom;;
    4) _remove_autoupdate_cron;;
    5) return 0;;
    *) echo "Opcao invalida";;
  esac
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
  show_menu
  read -rp "Escolha (1-9): " opt
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
      do_list_services
      ;;
    6)
      do_check_update || true
      ;;
    7)
      do_update || true
      ;;
    8)
      do_autoupdate || true
      ;;
    9)
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
