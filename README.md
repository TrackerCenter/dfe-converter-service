# DFe Converter — Setup de serviço (dfe-setup)

Este repositório contém um conjunto de scripts para instalar, remover e gerenciar o serviço do DFe Converter em Linux (systemd) e Windows (nssm). O objetivo é oferecer um "setup" interativo e reutilizável, com registro do estado em um arquivo JSON por instalação.

Arquivos principais
- dfe-setup.sh        — Menu interativo (Linux)
- dfe-install.sh      — Instalador idempotente (Linux)
- dfe-uninstall.sh    — Desinstalador (Linux)
- dfe-bootstrap.sh    — Bootstrap para dependências (Linux: instala/valida `jq`)
- dfe-setup.ps1       — Menu interativo (Windows)
- dfe-install.ps1     — Instalador (Windows, usa nssm)
- dfe-uninstall.ps1   — Desinstalador (Windows)
- `<INSTALL_DIR>/.dfe-setup.json` — arquivo de estado gerado por instalação (ex.: `/opt/.../.dfe-setup.json`)

Visão geral
- Cada instalação grava/atualiza um arquivo JSON em `<INSTALL_DIR>/.dfe-setup.json` contendo uma lista `installations` com as entradas daquela pasta.
- Isso permite múltiplas configurações/serviços e possibilita que o desinstalador remova apenas a entrada correspondente.
- O menu (`dfe-setup.*`) orquestra (invoca instalador/desinstalador); os scripts `dfe-install*` / `dfe-uninstall*` podem ser usados standalone.

Requisitos (geral)
- Linux:
    - systemd (para gerenciamento de serviços).
    - utilitários padrão: bash, coreutils, cp, chmod, chown, systemctl, sha256sum/cmp, curl/wget.
    - `jq` é necessário para manipular o JSON local; o `dfe-bootstrap.sh` tenta instalar `jq` automaticamente se ausente.
    - executar como root (sudo) para operações que alteram o sistema.
- Windows:
    - PowerShell (preferível PowerShell 7+), privilégios Administrador.
    - `nssm` será baixado automaticamente se necessário (requer acesso à internet) ou você pode colocá-lo em `InstallDir\nssm.exe`.
    - A execução do PowerShell deve permitir scripts (ExecutionPolicy Bypass ao invocar diretamente).

Observação sobre Python
- Os scripts Linux foram atualizados para usar `jq` (não dependem de `python3` para manipular o JSON). No Windows, PowerShell usa JSON nativo.

Raw URLs e robustez
- Para baixar scripts diretamente do GitHub raw há duas formas que funcionam:
    - padrão comum:  
      `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/scripts/<file>`
    - alternativa observada (equivalente):  
      `https://raw.githubusercontent.com/<owner>/<repo>/refs/heads/<branch>/scripts/<file>`
- Recomendações:
    - Para produção/automatização prefira apontar para um commit SHA ou tag (imutabilidade). Exemplo:
      `https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/<COMMIT_SHA>/scripts/dfe-setup.sh`
    - Os scripts `dfe-setup.sh` e `dfe-setup.ps1` suportam a variável de ambiente `DFESCRIPTS_RAW_BASE` para sobrescrever a base raw (útil para apontar para um commit/tag ou mirror interno). Exemplo:
      `export DFESCRIPTS_RAW_BASE="https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/<COMMIT_SHA>/scripts"`

Exemplos de execução (one-liners)
- Linux (menu, padrão):
  ```bash
  sudo bash <(curl -sSL https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts/dfe-setup.sh)
  ```
    - Rodar sem prompts para instalação automática de `jq`:
  ```bash
  sudo AUTO_INSTALL_JQ=1 bash <(curl -sSL https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts/dfe-setup.sh)
  ```

- Windows (PowerShell, execute como Administrador):
  ```powershell
  iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts/dfe-setup.ps1')
  ```

Uso manual (Linux)
1. Dê permissão de execução:
   ```bash
   chmod +x dfe-setup.sh dfe-install.sh dfe-uninstall.sh dfe-bootstrap.sh
   ```
2. Executar o menu:
   ```bash
   sudo ./dfe-setup.sh
   ```
3. Executar o instalador diretamente (exemplos):
    - Interativo (aceitar defaults):
      ```bash
      sudo ./dfe-install.sh
      ```
    - Não interativo (aceita defaults):
      ```bash
      sudo ./dfe-install.sh --yes
      ```
    - Especificando diretório e JAR:
      ```bash
      sudo ./dfe-install.sh --install-dir /opt/DFE_CONVERTER_PROD --jar-source /tmp/DFe-Converter-PROD.jar --config-source /tmp/config.properties
      ```
    - Desinstalar (direto):
      ```bash
      sudo ./dfe-uninstall.sh --service DFeConverterPROD --install-dir /opt/DFE_CONVERTER_PROD
      ```

Uso manual (Windows)
1. Abra PowerShell como Administrador.
2. Execute o menu:
   ```powershell
   & "C:\caminho\para\dfe-setup.ps1"
   ```
   ou rode o one-liner (conforme seção anterior).
3. Executar o instalador diretamente:
   ```powershell
   & "C:\caminho\para\dfe-install.ps1" -InstallDir "C:\Program Files\DFE_Converter_QA"
   ```
4. Executar o desinstalador diretamente:
   ```powershell
   & "C:\caminho\para\dfe-uninstall.ps1" -InstallDir "C:\Program Files\DFE_Converter_QA"
   ```

Arquivo de estado: `<INSTALL_DIR>/.dfe-setup.json`
- Local: cada instalação grava seu arquivo em `<INSTALL_DIR>/.dfe-setup.json` (visível e de fácil acesso).
- Estrutura:
  ```json
  {
    "installations": [
      {
        "serviceName": "DFeConverterQA",
        "jarName": "DFe-Converter-QA.jar",
        "configName": "config.properties",
        "javaPath": "/opt/DFE_CONVERTER_QA/java/bin/java",
        "logsEnabled": false,
        "installDir": "/opt/DFE_CONVERTER_QA",
        "installedAt": "2025-11-26T12:34:56Z",
        "installedBy": "rodrigocananea",
        "os": "linux"
      }
    ]
  }
  ```
- Regras:
    - Ao instalar: o instalador adiciona ou atualiza a entrada no array `installations` do arquivo.
    - Ao desinstalar: o desinstalador remove apenas a entrada com `serviceName` correspondente; se o array ficar vazio, o arquivo é removido.
    - Suporta múltiplas entradas (para casos onde a mesma pasta contenha várias configurações/serviços).

Permissões e segurança
- O arquivo `.dfe-setup.json` fica em local acessível por design. Para proteção:
    - No Linux deixe o diretório de instalação com permissões corretas (por exemplo: dono `root` ou usuário do serviço; modo 0755 para o diretório e 0640 para o arquivo se quiser restringir leitura).
    - No Windows use `C:\Program Files\...` ou `C:\ProgramData\...` e ajuste ACLs se necessário.
- One-liners executam código remoto. Em ambientes sensíveis, prefira:
    - baixar os scripts, verificar hash/assinatura e inspecionar antes de executar; ou
    - usar `DFESCRIPTS_RAW_BASE` apontando para um commit SHA testado.

Bootstrap e `jq`
- O script `dfe-bootstrap.sh` garante que `jq` (necessário nos scripts Linux) esteja disponível:
    - tenta detectar package manager e executar a instalação (interativo por padrão);
    - faz fallback para baixar o binário oficial do GitHub (ou instalar localmente em `~/.local/bin` se sem privilégio root);
    - para automação/CI use `AUTO_INSTALL_JQ=1` para instalar sem prompt:
      ```bash
      sudo AUTO_INSTALL_JQ=1 ./dfe-setup.sh
      ```
    - se preferir instalar `jq` manualmente, exemplos:
      ```bash
      # Debian/Ubuntu
      sudo apt-get update && sudo apt-get install -y jq
  
      # Alpine
      sudo apk add --no-cache jq
  
      # RHEL/CentOS (dnf/yum)
      sudo dnf install -y jq
      ```

Opções e flags importantes
- dfe-install.sh:
    - --yes            : aceita defaults sem perguntas
    - --install-dir    : diretório de instalação
    - --jar-source     : caminho para JAR de origem
    - --config-source  : caminho para config.properties (opcional)
    - --no-start       : não iniciar/habilitar o serviço no final
    - --force          : sobrescrever unit/env sem perguntar
- dfe-uninstall.sh:
    - --service NAME   : nome do systemd service a remover
    - --install-dir    : diretório de instalação (atualiza .dfe-setup.json nesse local)
- dfe-install.ps1 / dfe-uninstall.ps1 (Windows):
    - dfe-install.ps1 aceita -InstallDir e -EnableAppLogs (via menu interativo também).
    - dfe-uninstall.ps1 aceita -InstallDir para que o JSON naquele local seja atualizado.

Solução de problemas comum
- "systemctl: not found" ou sistema não usa systemd:
    - O instalador cria unidades systemd. Se o sistema não usa systemd, o instalador irá criar arquivos, mas não gerenciará o serviço automaticamente.
- "nssm download falhou" (Windows):
    - Verifique acesso à internet ou coloque `nssm.exe` manualmente no `InstallDir`.
- PowerShell: "execution policy" ou permissão:
    - Execute PowerShell como Administrador e use `-ExecutionPolicy Bypass` conforme mostrado.
