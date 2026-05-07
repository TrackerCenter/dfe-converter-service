# DFe Converter — Setup de serviço

Scripts interativos para instalar, atualizar e gerenciar o serviço **DFe Converter** em Linux (systemd) e Windows (nssm).

---

## ⚡ Início Rápido

> ⚠️ **Execute sempre como `root`/`sudo` no Linux ou como Administrador no Windows.**  
> Os scripts criam serviços do sistema, escrevem em `/opt` e manipulam o systemd/nssm.

### Linux

> ⚠️ **Não use `sudo bash <(curl ...)` — o `sudo` não herda o file descriptor criado pelo `<()` e causa `No such file or directory`.**

Se já estiver como **root** (ex: `root@servidor`):
```bash
bash <(curl -sSL https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup)
```

Se precisar usar **sudo** (usuário comum), use pipe em vez de process substitution:
```bash
curl -sSL https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup | sudo bash
```

Ou salve o script em disco e execute:
```bash
curl -sSL https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup -o /tmp/dfe-setup.sh
sudo bash /tmp/dfe-setup.sh
```

### Windows (PowerShell como Administrador)

> ⚠️ **Antivírus (Kaspersky, Defender, etc.) pode bloquear `iex` executando conteúdo remoto diretamente da memória.**  
> Use o padrão seguro: baixe o script para disco primeiro e então execute-o.

```powershell
# Baixar e executar (padrão seguro — não é bloqueado por antivírus)
iwr -useb https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup `
    -OutFile "$env:TEMP\dfe-setup.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\dfe-setup.ps1"
```

Ou em uma linha só:

```powershell
iwr -useb https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup -OutFile "$env:TEMP\dfe-setup.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\dfe-setup.ps1"
```

> Os scripts são servidos diretamente pelo Tracker. Não é necessário instalar nada previamente — somente `curl` (Linux) ou acesso à internet (Windows).

---

## Menu Principal

Ao executar o setup, o seguinte menu é exibido:

```
==========================================================
                    MENU PRINCIPAL
==========================================================

  1) Instalar service
  2) Remover service
  3) Reinstalar service (manter EXE/config)
  4) Status do service
  5) Listar servicos dfe instalados
  6) Verificar atualizacao
  7) Baixar e atualizar EXE
  8) Configurar auto-update
  9) Sair
```

| Opção | Descrição | Documentação |
|------:|-----------|:---:|
| **1) Instalar service** | Baixa o executável (QA ou PROD), gera o `config.properties` interativamente e registra o serviço no systemd/nssm. | [→ Guia de Instalação](docs/instalacao.md) |
| **2) Remover service** | Para e remove o serviço e a pasta de instalação. | [→ Guia de Instalação](docs/instalacao.md#remover-service-opção-2) |
| **3) Reinstalar service** | Recria apenas o serviço (systemd/nssm) sem tocar no EXE/JAR ou `config.properties`. | [→ Guia de Instalação](docs/instalacao.md#reinstalar-opção-3) |
| **4) Status do service** | Lista todos os serviços `dfe-*` detectados e mostra o status. | [→ Guia de Instalação](docs/instalacao.md#status-do-service-opção-4) |
| **5) Listar serviços** | Exibe todos os serviços `dfe-*` instalados com versão e diretório. | [→ Guia de Instalação](docs/instalacao.md#listar-serviços-opção-5) |
| **6) Verificar atualização** | Consulta o servidor e exibe versões disponíveis (QA e PROD). Compara com a versão instalada. | [→ Guia de Atualização](docs/atualizacao.md) |
| **7) Baixar e atualizar EXE** | Baixa e instala o executável mais recente sobre uma instalação existente. | [→ Guia de Atualização](docs/atualizacao.md#baixar-e-atualizar-jar-opção-7) |
| **8) Configurar auto-update** | Cria um script agendado via cron (Linux) ou Task Scheduler (Windows) para atualização automática. | [→ Guia de Atualização](docs/atualizacao.md#configurar-auto-update-opção-8) |

---

## Requisitos

### Linux
- `bash` 4.0+, `curl` ou `wget`, `sha256sum`, `systemctl`
- Execução como **root** (ou via `sudo`)
- **Java 8:** detectado automaticamente — se não estiver presente ou for versão incompatível, o setup oferece download automático do [Zulu OpenJDK 8](https://www.azul.com/downloads/?package=jdk#zulu) (sem necessidade de instalação manual)

### Windows
- PowerShell 5.1+ (recomendado PowerShell 7+)
- Execução como **Administrador**
- `nssm` é baixado automaticamente se ausente

---

## Status de implantação

| Branch | Versão | Descrição | Status |
|--------|--------|-----------|--------|
| `develop` (v1.10.0) | `dfe-setup.sh` | Auto-download Zulu Java 8 quando Java não encontrado | ✅ Mergeado |
| `fix/dfe-setup-java-postcfg` | `dfe-setup.sh` | Correção: configurar `JAVA_CMD` pós-instalação sem passar `--java-home` ao instalador remoto | ⏳ Aguardando PR |

> **Nota sobre `fix/dfe-setup-java-postcfg`:** a v1.10.0 passava `--java-home` diretamente ao `dfe-install.sh` baixado do servidor, mas o instalador remoto pode ser uma versão anterior sem suporte ao parâmetro. O fix aplica a configuração de Java diretamente no `/etc/default/<service>` após a instalação, mantendo compatibilidade com qualquer versão do instalador.

---

## Arquivos do repositório

| Arquivo | Descrição |
|---------|-----------|
| `scripts/dfe-setup.sh` | Menu interativo — Linux |
| `scripts/dfe-install.sh` | Instalador idempotente — Linux |
| `scripts/dfe-uninstall.sh` | Desinstalador — Linux |
| `scripts/dfe-update.sh` | Atualizador de JAR — Linux |
| `scripts/dfe-bootstrap.sh` | Valida dependências — Linux |
| `scripts/dfe-setup.ps1` | Menu interativo — Windows |
| `scripts/dfe-install.ps1` | Instalador — Windows |
| `scripts/dfe-uninstall.ps1` | Desinstalador — Windows |
| `config.properties.example` | Modelo de configuração do DFe Converter |
| `docs/instalacao.md` | Guia detalhado de instalação e remoção |
| `docs/atualizacao.md` | Guia de atualização manual e automática |
| `docs/solucao-problemas.md` | Diagnóstico de erros comuns |

---

## Documentação adicional

- 📦 [Guia de Instalação](docs/instalacao.md) — instalar, reinstalar, remover e verificar status
- 🔄 [Guia de Atualização](docs/atualizacao.md) — atualizar JAR e configurar auto-update
- 🔧 [Solução de Problemas](docs/solucao-problemas.md) — erros comuns e como resolver
