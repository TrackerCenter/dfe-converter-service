# Guia de Instalação — DFe Converter

> ⚠️ Todos os comandos requerem **root/sudo** no Linux ou **Administrador** no Windows.

---

## Sumário

- [Instalar service (opção 1)](#instalar-service-opção-1)
  - [1. Selecionar servidor](#1-selecionar-servidor)
  - [2. Selecionar executável (QA ou PROD)](#2-selecionar-executável-qa-ou-prod)
  - [3. Confirmar versão](#3-confirmar-versão)
  - [4. Configurar o DFe Converter](#4-configurar-o-dfe-converter)
  - [5. Download e instalação](#5-download-e-instalação)
  - [O que é criado após a instalação](#o-que-é-criado-após-a-instalação)
- [Remover service (opção 2)](#remover-service-opção-2)
- [Reinstalar (opção 3)](#reinstalar-opção-3)
- [Status do service (opção 4)](#status-do-service-opção-4)
- [Listar serviços (opção 5)](#listar-serviços-opção-5)
- [Referência: config.properties](#referência-configproperties)

---

## Instalar service (opção 1)

O setup guia todo o processo em etapas.

### 1. Selecionar servidor

Ao iniciar qualquer operação, o setup pergunta de qual servidor Tracker buscar os scripts e executáveis.

```
==========================================================
         SELECIONAR SERVIDOR DO TRACKER
==========================================================

  Define de onde baixar os scripts e executaveis.
  Ambos os servidores contem executaveis de QA e PROD.

  1) QA   - https://qa.trackercenter.com.br/app (mais recente)
  2) PROD - https://prod.trackercenter.com.br/app (estavel)
  3) URL personalizada

Escolha (1-3):
```

> **Dica:** o servidor define apenas *de onde* os scripts são baixados — não qual executável será instalado.  
> O servidor QA sempre terá as versões mais recentes (inclusive a futura versão PROD).  
> Use o servidor PROD para ambientes que precisam de mais estabilidade.

### 2. Selecionar executável (QA ou PROD)

Após escolher o servidor, o setup pergunta qual variante do DFe Converter instalar:

```
==========================================================
     VERSAO DO DFe CONVERTER A INSTALAR/ATUALIZAR
==========================================================

  1) QA   - DFe-Converter-QA.jar  (homologacao/testes)
  2) PROD - DFe-Converter-PROD.jar (producao)

Escolha (1-2):
```

| Variante | JAR | Diretório padrão | Nome do serviço |
|----------|-----|-----------------|-----------------|
| **QA** | `DFe-Converter-QA.jar` | `/opt/DFE_CONVERTER_QA` | `dfe-converter-qa` |
| **PROD** | `DFe-Converter-PROD.jar` | `/opt/DFE_CONVERTER_PROD` | `dfe-converter-prod` |

> É possível ter QA e PROD instalados simultaneamente no mesmo servidor em diretórios diferentes.

### 3. Confirmar versão

O setup exibe os dados da versão disponível antes de prosseguir:

```
==========================================================
         VERSAO DISPONIVEL PARA INSTALACAO
==========================================================

  Ambiente : PROD
  Versao   : 2.38
  Arquivo  : DFe-Converter-PROD.jar
  Tamanho  : 75 MB
  Data     : 2026-05-03T20:26:51Z

Prosseguir com a instalacao? [S/n]:
```

### 4. Configurar o DFe Converter

O setup solicita os dados essenciais para gerar o `config.properties`:

```
==========================================================
      CONFIGURACAO DO DFe CONVERTER
==========================================================

  Pressione ENTER para aceitar o valor padrao.

  sync.tenant (identificador do cliente, obrigatorio): minha-empresa
  sync.port [9393]:
  sync.intervaloMinutos [15]:

  Pastas (separe multiplos caminhos com ;)

  Pasta de entrada (sincronizacao) [/dados/xmls]: /var/dfe/entrada
  Pasta de saida (convertido) [/dados/saida]: /var/dfe/saida
  Pasta de processamento [/dados/processado]: /var/dfe/processado
  Pasta de relatorio [/dados/relatorio]: /var/dfe/relatorio
```

> O campo **`sync.tenant`** é obrigatório — identifica o cliente no sistema Tracker.  
> Para múltiplas pastas de entrada, separe com `;`: `/var/dfe/nfe;/var/dfe/cte`

Após coletar os dados, o `config.properties` é gerado automaticamente e colocado no diretório de instalação. Consulte a [referência completa do config.properties](#referência-configproperties) para ajustes pós-instalação.

### 5. Download e instalação

O setup baixa o JAR com barra de progresso e executa o instalador:

```
2026-05-03T22:00:00Z Baixando DFe-Converter-PROD.jar (PROD v2.38)...
######################################################################### 100.0%

2026-05-03T22:00:45Z Executando instalador...
2026-05-03T22:00:46Z Servico dfe-converter-prod instalado com sucesso.
2026-05-03T22:00:46Z Servico iniciado: dfe-converter-prod
```

### O que é criado após a instalação

```
/opt/DFE_CONVERTER_PROD/
├── DFe-Converter-PROD.jar      # executável principal
├── config.properties           # configuração gerada pelo setup
├── java/                       # JRE embarcado (se baixado pelo instalador)
└── .dfe-setup.env              # estado da instalação (não editar manualmente)
```

O serviço systemd é registrado em `/etc/systemd/system/dfe-converter-prod.service` e iniciado automaticamente.

Para verificar:

```bash
sudo systemctl status dfe-converter-prod
```

---

## Remover service (opção 2)

Para desinstalar um serviço existente:

1. Escolha **2) Remover service** no menu
2. O setup detecta automaticamente os serviços `dfe-*` instalados e pergunta qual remover:

```
==========================================================
         SELECIONAR INSTALACAO
==========================================================

  1) /opt/DFE_CONVERTER_QA    service=dfe-converter-qa   versao=2.38
  2) /opt/DFE_CONVERTER_PROD  service=dfe-converter-prod  versao=2.38

Escolha a instalacao (1-2):
```

O desinstalador:
- Para e desabilita o serviço systemd
- Remove a unit file de `/etc/systemd/system/`
- Remove o diretório de instalação (após confirmação)

---

## Reinstalar (opção 3)

Equivale a **Remover + Instalar** em sequência. Útil para:
- Trocar de QA para PROD (ou vice-versa)
- Corrigir instalações corrompidas
- Atualizar `config.properties` com novos parâmetros

O setup pergunta os mesmos dados de configuração que a instalação inicial.

---

## Status do service (opção 4)

Lista todos os serviços `dfe-*` detectados e exibe o status completo:

```
==========================================================
         SELECIONAR SERVICO
==========================================================

  1) dfe-converter-qa   (/opt/DFE_CONVERTER_QA)
  2) dfe-converter-prod (/opt/DFE_CONVERTER_PROD)

Escolha (1-2): 1

==========================================================
              STATUS DO SERVICO
==========================================================

● dfe-converter-qa.service - dfe-converter-qa
     Loaded: loaded (/etc/systemd/system/dfe-converter-qa.service; enabled)
     Active: active (running) since Sun 2026-05-03 22:00:00 -03; 5min ago
   Main PID: 12345 (java)
        CPU: 1.2s
```

Se o serviço estiver com falha, as últimas linhas do journal são exibidas para diagnóstico. Após a exibição, pressione ENTER para voltar ao menu.

**Serviço com erro `java: not found`**

```
/bin/sh: 1: exec: java: not found
```

Significa que o Java não está instalado ou não está no `PATH`. Instale com:

```bash
# Debian/Ubuntu
sudo apt-get install -y default-jre-headless

# RHEL/CentOS
sudo dnf install -y java-17-openjdk-headless

# Verificar
java -version
```

---

## Listar serviços (opção 5)

Exibe todos os serviços `dfe-*` com status, versão e diretório:

```
  SERVIÇO                                  STATUS       ATIVO      DESCRIÇÃO
  -----------------------------------------------------------------------
  dfe-converter-qa.service                 active       enabled    dfe-converter-qa
  dfe-converter-prod.service               inactive     disabled   dfe-converter-prod
```

---

## Referência: config.properties

O arquivo fica em `<INSTALL_DIR>/config.properties` e pode ser editado após a instalação.  
Reinicie o serviço após qualquer alteração:

```bash
sudo systemctl restart dfe-converter-prod
```

### Seção principal (`sync.*`)

| Propriedade | Padrão | Obrigatório | Descrição |
|-------------|--------|:-----------:|-----------|
| `sync.tenant` | — | ✅ | Identificador do cliente no sistema Tracker |
| `sync.port` | `9393` | | Porta HTTP da API local do DFe Converter |
| `sync.intervaloMinutos` | `15` | | Intervalo em minutos entre sincronizações |
| `sync.tamanhoLoteEnvio` | `2000` | | Quantidade máxima de documentos por lote |
| `sync.padraoSaidaTr` | `true` | | Usa o formato de saída padrão TR |
| `sync.ignorarTagsReformaTributaria` | `true` | | Ignora tags da reforma tributária no XML |
| `sync.proxySalvarArquivoOriginal` | `true` | | Salva o arquivo XML original antes de converter |
| `sync.proxySalvarArquivoConvertido` | `true` | | Salva o XML convertido após envio |

### Proxy de envio (`sync.proxy*`)

Configura o envio dos documentos para uma API REST externa.

| Propriedade | Exemplo | Descrição |
|-------------|---------|-----------|
| `sync.proxyConfig` | `POST\|/api/nfe\|txt_conteudo.xml` | `MÉTODO\|ROTA\|CAMPO_XML` — múltiplos separados por `;` |
| `sync.proxyBaseUrl` | `https://ws.h.dfe.mastersaf.com.br` | URL base da API de destino |
| `sync.proxyEstrategiaErro` | `IGNORAR` | `IGNORAR` / `RETORNAR_ERRO` / `SALVAR_ERRO_E_SEGUIR` |

### Proxy de internet (`internet.proxy.*`)

| Propriedade | Padrão | Descrição |
|-------------|--------|-----------|
| `internet.proxy.enabled` | `false` | Ativa proxy HTTP de saída |
| `internet.proxy.host` | — | Endereço do proxy |
| `internet.proxy.port` | — | Porta do proxy |
| `internet.proxy.username` | — | Usuário (opcional) |
| `internet.proxy.password` | — | Senha (opcional) |

### Pastas por tipo de documento

As propriedades de pasta seguem o mesmo padrão para `nfe`, `cte` e `nfse`.  
Múltiplos caminhos são separados por `;`.

| Propriedade | Padrão | Descrição |
|-------------|--------|-----------|
| `nfe.pastas.sincronizacao` | `/dados/xmls` | Pasta(s) monitoradas para NF-e |
| `nfe.pasta.convertido` | `/dados/saida` | Destino dos XMLs convertidos |
| `nfe.pasta.processamento` | `/dados/processado` | Arquivos já enviados |
| `nfe.pasta.relatorio` | `/dados/relatorio` | Relatórios de processamento |
| `nfe.criarTagVNFTot` | `true` | Gera a tag `<vNFTot>` no XML de saída |
| `cte.pastas.sincronizacao` | `/dados/xmls` | Pasta(s) monitoradas para CT-e |
| `cte.pasta.convertido` | `/dados/saida` | Destino dos XMLs convertidos (CT-e) |
| `nfse.pastas.sincronizacao` | `/dados/xmls` | Pasta(s) monitoradas para NFS-e |
| `nfse.pasta.convertido` | `/dados/saida` | Destino dos XMLs convertidos (NFS-e) |

### Exemplo completo

```properties
# Identificação
sync.tenant=minha-empresa
sync.port=9393
sync.intervaloMinutos=15
sync.tamanhoLoteEnvio=2000

# Comportamento
sync.padraoSaidaTr=true
sync.ignorarTagsReformaTributaria=true
sync.proxySalvarArquivoOriginal=true
sync.proxySalvarArquivoConvertido=true

# Envio para API (ajuste conforme seu ambiente)
sync.proxyConfig=POST|/api/nfe|txt_conteudo.xml
sync.proxyBaseUrl=https://ws.h.dfe.mastersaf.com.br
sync.proxyEstrategiaErro=IGNORAR

# Proxy de internet (desativado por padrão)
internet.proxy.enabled=false
internet.proxy.host=proxy.empresa.com
internet.proxy.port=3128

# NF-e — múltiplas pastas de entrada separadas por ;
nfe.pastas.sincronizacao=/var/dfe/nfe/entrada;/mnt/share/nfe
nfe.pasta.convertido=/var/dfe/nfe/saida
nfe.pasta.processamento=/var/dfe/nfe/processado
nfe.pasta.relatorio=/var/dfe/nfe/relatorio
nfe.criarTagVNFTot=true

# CT-e
cte.pastas.sincronizacao=/var/dfe/cte/entrada
cte.pasta.convertido=/var/dfe/cte/saida
cte.pasta.processamento=/var/dfe/cte/processado
cte.pasta.relatorio=/var/dfe/cte/relatorio

# NFS-e
nfse.pastas.sincronizacao=/var/dfe/nfse/entrada
nfse.pasta.convertido=/var/dfe/nfse/saida
nfse.pasta.processamento=/var/dfe/nfse/processado
nfse.pasta.relatorio=/var/dfe/nfse/relatorio
```
