# install-service.sh

Script idempotente para instalar e configurar um serviço systemd que executa um JAR (DFe-Converter)
a partir de um diretório. O script foi projetado para ambientes corporativos onde você pode não ter
permissão para instalar novos pacotes — ele usa apenas utilitários normalmente presentes em Linux
(root/sudo necessário).

Versão do script referenciada: `install-service.sh`

---

## Objetivo
- Criar (quando não existirem) usuário e grupo de sistema para rodar o serviço.
- Criar diretório de instalação (por padrão `/opt/DFE_CONVERTER_QA`) e garantir permissões.
- Copiar o JAR e o arquivo de configuração (se fornecido) apenas quando necessário (comparo por SHA-256 / cmp).
- Criar `/etc/default/<service>` para overrides operacionais (JAVA_CMD, JAVA_OPTS, EXTRA_OPTS).
- Criar/atualizar a unit systemd `/etc/systemd/system/<service>.service`.
- Fazer backup de arquivos sobrescritos e reiniciar o serviço somente quando necessário.
- Ser seguro para re-execuções (idempotente) e interativo por padrão.

---

## Requisitos (runtime)
- Executar como root (ou via `sudo`).
- Comandos esperados:
    - systemctl
    - useradd, groupadd
    - cp, mkdir, chmod, chown
    - sha256sum ou shasum ou cmp (para comparação de arquivos)
    - readlink (opcional; usado para detectar java)
- Nota: o script NÃO instala pacotes adicionais. Se algum utilitário estiver ausente, o script tentará um fallback conservador.

---

## Uso

Modo interativo (padrão):
```bash
sudo ./install-service.sh
```

Modo não interativo/automação:
- Aceitar todos os defaults:
```bash
sudo ./install-service.sh --yes
```

- Informando caminho do JAR/config:
```bash
sudo ./install-service.sh --jar-source /tmp/DFe-Converter-QA.jar --config-source /tmp/config.properties
```

Opções:
- `--yes` : aceita todos os defaults sem perguntas (útil em pipelines).
- `--jar-source PATH` : caminho para o JAR de origem (se não fornecido, o script pergunta).
- `--config-source PATH` : caminho para config.properties (opcional).
- `--no-start` : não iniciar/habilitar o serviço ao final.
- `--force` : sobrescrever `/etc/default/<service>` e a unit sem interatividade (faz backup antes).
- `-h, --help` : exibe ajuda.

Exemplo completo:
```bash
sudo ./install-service.sh --jar-source /tmp/DFe-Converter-QA.jar \
  --config-source /tmp/config.properties --yes
```

---

## Comportamento / Fluxo de execução (resumido)
1. Verifica execução como root.
2. Pergunta (ou usa defaults) sobre:
    - Nome do serviço (default `dfe-converter-qa`)
    - Usuário do sistema (default `dfeconv`)
    - Diretório de instalação (default `/opt/DFE_CONVERTER_QA`)
    - Caminho do JAR de origem (obrigatório)
    - Caminho do config (opcional)
    - Nome do JAR/config no destino e `JAVA_OPTS`
3. Detecta init system (systemd vs outros). O script gerencia automaticamente systemd; para upstart/sysv apenas copia arquivos (pode ser adaptado se precisar).
4. Cria grupo/usuário apenas se não existirem.
5. Cria diretório de instalação (se necessário) e aplica ownership/perms.
6. Compara JAR e config origem x destino:
    - usa SHA-256 quando disponível; senão `cmp`.
    - só copia se os conteúdos forem diferentes (ou destino ausente).
7. Cria `/etc/default/<service>` com o template padrão (ou pergunta antes de sobrescrever se houver arquivo e `--force` não foi usado). Faz backup do arquivo existente com timestamp antes de sobrescrever.
8. Gera `/etc/systemd/system/<service>.service` (se systemd) com `EnvironmentFile=-/etc/default/<service>` e `ExecStart` que usa `JAVA_CMD`/`JAVA_OPTS` do env file.
9. Se unit/env foram criados/alterados, executa `systemctl daemon-reload`.
10. Decide reiniciar/ligar o serviço:
    - Se o serviço já está ativo e houve mudanças relevantes (JAR/config/unit/env) → reinicia.
    - Se o serviço não está ativo e `--no-start` não foi passado → habilita e inicia.
    - Se `--no-start` foi usado → não inicia.
11. Log final com resumo das ações realizadas.

---

## Arquivos criados / modificados
- Diretório de instalação (padrão): `/opt/DFE_CONVERTER_QA`
    - JAR copiado para: `/opt/DFE_CONVERTER_QA/DFe-Converter-QA.jar` (nome alterável no prompt)
    - Config copiado para: `/opt/DFE_CONVERTER_QA/config.properties` (se fornecido)
- Unit systemd: `/etc/systemd/system/<service>.service` (por padrão `/etc/systemd/system/dfe-converter-qa.service`)
- Arquivo de ambiente: `/etc/default/<service>` (para overrides: JAVA_CMD, JAVA_OPTS, EXTRA_OPTS)
- Backups (se arquivos pré-existiam e foram sobrescritos):
    - `/etc/default/<service>.bak.YYYYMMDDhhmmss`
    - `/etc/systemd/system/<service>.service.bak.YYYYMMDDhhmmss`

---

## Idempotência e segurança
- O script é idempotente: re-execuções só realizam alterações quando o conteúdo difere.
- Comparação por SHA-256 quando disponível para evitar cópias desnecessárias.
- Backups são feitos antes de sobrescrever arquivos críticos como unit/env.
- Usuário/grupo só são criados se inexistentes, evitando conflito com políticas de LDAP/AD.
- Permissões aplicadas:
    - JAR: `0550`, dono: `<user>:<group>`
    - Config: `0640`, dono: `<user>:<group>`
    - /etc files: `0644` (root)

---

## Logs e verificação
- Visualizar logs do serviço (systemd):
```bash
sudo journalctl -u dfe-converter-qa -f
```
- Status:
```bash
sudo systemctl status dfe-converter-qa
```
- Verificar unit e env:
```bash
sudo cat /etc/systemd/system/dfe-converter-qa.service
sudo cat /etc/default/dfe-converter-qa
```

---

## Atualizações / reinstalações
- Re-executar o script:
    - se o JAR/config forem idênticos, não ocorrerá recópia;
    - se houver novas versões do JAR, o script fará backup da unit/env (quando aplicável), copiará o novo JAR e reiniciará o serviço se ele estiver ativo;
- Para forçar atualização não interativa, use `--force` (sobrescreve unit/env) e/ou atualize o JAR de origem e execute com `--yes` para manter defaults.

---

## Remoção / rollback manual
Se quiser remover tudo que o script criou (exemplo manual):
```bash
sudo systemctl stop dfe-converter-qa
sudo systemctl disable dfe-converter-qa
sudo rm -f /etc/systemd/system/dfe-converter-qa.service
sudo rm -f /etc/default/dfe-converter-qa
sudo systemctl daemon-reload
# (opcional) remover arquivos de instalação e usuário:
sudo rm -rf /opt/DFE_CONVERTER_QA
# Remover usuário/grupo (CUIDADO se compartilhado):
sudo userdel dfeconv || true
sudo groupdel dfeconv || true
```
Tenha cuidado ao remover usuário/grupo se eles forem usados por outros serviços.

---

## Exemplo de fluxo rápido
1. Copie `install-service.sh` para o servidor.
2. Torne o script executável:
```bash
chmod +x install-service.sh
```
3. Execute (interativo):
```bash
sudo ./install-service.sh
```
4. Ou execute sem prompts usando os defaults:
```bash
sudo ./install-service.sh --yes --jar-source /tmp/DFe-Converter-QA.jar --config-source /tmp/config.properties
```


