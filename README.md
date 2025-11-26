# DFe Converter — Setup de serviço (dfe-setup)

Este repositório contém um conjunto de scripts para instalar, remover e gerenciar o serviço do DFe Converter em Linux (systemd) e Windows (nssm). O objetivo é oferecer um "setup" interativo e reutilizável, com registro do estado em um arquivo JSON por instalação.

Arquivos principais
- dfe-setup.sh        — Menu interativo (Linux)
- dfe-install.sh      — Instalador idempotente (Linux)
- dfe-uninstall.sh    — Desinstalador (Linux)
- dfe-setup.ps1       — Menu interativo (Windows)
- dfe-install.ps1     — Instalador (Windows, usa nssm)
- dfe-uninstall.ps1   — Desinstalador (Windows)
- .dfe-setup.json     — arquivo de estado gerado dentro de cada INSTALL_DIR (ex.: `<INSTALL_DIR>/.dfe-setup.json`)

Visão geral
- Cada instalação grava/atualiza um arquivo JSON em `<INSTALL_DIR>/.dfe-setup.json` contendo uma lista `installations` com as entradas daquela pasta.
- Isso permite múltiplas configurações/serviços e possibilita que o desinstalador remova apenas a entrada correspondente.
- O menu (`dfe-setup.*`) apenas orquestra (invoca instalador/desinstalador); você pode também usar os scripts `dfe-install*` / `dfe-uninstall*` de forma standalone.

Requisitos (geral)
- Linux:
    - systemd (para gerenciamento de serviços).
    - utilitários padrão: bash, coreutils, cp, chmod, chown, systemctl, sha256sum/cmp, python3 (ou python).
    - executar como root (sudo).
- Windows:
    - PowerShell (preferível PowerShell 7+), privilégios Administrador.
    - nssm será baixado automaticamente se necessário (requer acesso à internet) ou você pode colocá-lo em `InstallDir\nssm.exe`.
    - A execução do PowerShell deve permitir scripts (ExecutionPolicy Bypass ao invocar diretamente).

Exemplos de execução (one-liners)
- Linux (executa o menu baixando o script raw do GitHub):
  ```bash
  sudo bash <(curl -sSL https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/main/scripts/dfe-setup.sh)
  ```
  Observação: assegure que a URL aponte para a branch correta (ex.: `main`).

- Windows (execute em PowerShell como Administrador):
  ```powershell
  iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/main/scripts/dfe-setup.ps1')
  ```
  Observação: este comando baixa e executa o script remoto — adote verificações/assinaturas em ambiente sensível.

Uso manual (Linux)
1. Dê permissão de execução:
   ```bash
   chmod +x dfe-setup.sh dfe-install.sh dfe-uninstall.sh
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
- Local: cada instalação grava seu arquivo em `<INSTALL_DIR>/.dfe-setup.json` (visível e de fácil acesso como você solicitou).
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
    - No Linux deixe o diretório de instalação com permissões corretas (por exemplo: dono `root` ou usuário do serviço; modo 0755 para o diretório e 0640 para o arquivo, se quiser restringir leitura).
    - No Windows use `C:\Program Files\...` ou `C:\ProgramData\...` e ajuste ACLs se necessário.
- One-liners executam código remoto. Em ambientes sensíveis, prefira baixar os arquivos, verificar hash e inspecionar antes de executar.

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
