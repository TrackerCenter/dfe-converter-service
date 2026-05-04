# Guia de Atualização — DFe Converter

> ⚠️ Todos os comandos requerem **root/sudo** no Linux.

---

## Sumário

- [Verificar atualização (opção 6)](#verificar-atualização-opção-6)
- [Baixar e atualizar JAR (opção 7)](#baixar-e-atualizar-jar-opção-7)
- [Configurar auto-update (opção 8)](#configurar-auto-update-opção-8)
  - [Opções de agendamento](#opções-de-agendamento)
  - [O que é gerado](#o-que-é-gerado)
  - [Verificar e desativar](#verificar-e-desativar)

---

## Verificar atualização (opção 6)

Consulta o servidor Tracker e exibe todas as versões disponíveis — tanto QA quanto PROD — comparando com a versão instalada.

### Exemplo de saída

```
==========================================================
       ARQUIVOS DISPONIVEIS NA ULTIMA VERSAO
==========================================================

  AMB    TIPO   NOME                                 VERSAO       TAMANHO  DATA UPLOAD
  -----------------------------------------------------------------------
  QA     JAR    DFe-Converter-QA.jar                 2.38           75 MB  2026-05-03T20:26:51Z
  QA     EXE    DFe-Converter-QA.exe                 2.38           75 MB  2026-05-03T20:28:13Z
  PROD   JAR    DFe-Converter-PROD.jar               2.38           75 MB  2026-05-03T20:26:51Z
  PROD   EXE    DFe-Converter-PROD.exe               2.38           75 MB  2026-05-03T20:28:13Z
```

Após exibir a tabela, o setup pergunta qual instalação existente verificar:

```
==========================================================
         SELECIONAR INSTALACAO
==========================================================

  1) /opt/DFE_CONVERTER_QA    service=dfe-converter-qa   versao=2.37
  2) /opt/DFE_CONVERTER_PROD  service=dfe-converter-prod  versao=2.38

Escolha a instalacao (1-2): 1

2026-05-03T22:00:00Z Estado: /opt/DFE_CONVERTER_QA/.dfe-setup.env
2026-05-03T22:00:00Z Instalacao detectada: service=dfe-converter-qa | versao=2.37 | ambiente=QA
2026-05-03T22:00:00Z Consultando versao disponivel: .../versoes/latest/info?ambiente=QA&tipo=JAR
2026-05-03T22:00:00Z Versao remota: 2.38 | Versao instalada: 2.37
2026-05-03T22:00:00Z ATUALIZACAO DISPONIVEL: 2.37 -> 2.38
```

> O ambiente usado para comparação (QA ou PROD) é lido automaticamente do arquivo de estado da instalação selecionada. Não é necessário informar manualmente.

---

## Baixar e atualizar JAR (opção 7)

Baixa o JAR mais recente e substitui o da instalação existente **sem alterar** o `config.properties` ou as configurações do serviço.

### Fluxo

1. **Selecionar servidor** — qual servidor Tracker consultar (QA URL ou PROD URL)
2. **Selecionar instalação** — detecta automaticamente diretórios com `.dfe-setup.env`
3. **Download com progresso** — exibe barra de progresso para o JAR (~75 MB)
4. **Substituição e restart** — substitui o JAR e reinicia o serviço automaticamente

### Exemplo de saída

```
==========================================================
         SELECIONAR INSTALACAO
==========================================================

  1) /opt/DFE_CONVERTER_QA    service=dfe-converter-qa   versao=2.37

Escolha a instalacao (1-1): 1

2026-05-03T22:00:00Z Instalacao: /opt/DFE_CONVERTER_QA | ambiente=QA | versao=2.37
2026-05-03T22:00:00Z Baixando DFe-Converter-QA.jar (QA v2.38)...
######################################################################### 100.0%
2026-05-03T22:00:45Z JAR atualizado com sucesso.
2026-05-03T22:00:45Z Reiniciando dfe-converter-qa...
2026-05-03T22:00:46Z Servico reiniciado.
```

> Se não houver instalação detectada nos locais padrão (`/opt`), o setup pergunta se deseja realizar uma **instalação inicial** e redireciona para a opção 1.

---

## Configurar auto-update (opção 8)

Cria um script agendado via **crontab** que verifica e aplica atualizações automaticamente, sem intervenção manual.

### Menu de configuração

```
==========================================================
           STATUS DO AUTO-UPDATE
==========================================================

  Status      : INATIVO

==========================================================

  1) Ativar - Todo dia as 01:00
  2) Ativar - Toda segunda-feira as 01:00
  3) Ativar - Personalizado (expressao cron)
  4) Desativar auto-update
  5) Voltar

Escolha (1-5):
```

### Opções de agendamento

| Opção | Expressão cron | Descrição |
|------:|---------------|-----------|
| **1** | `0 1 * * *` | Todo dia às 01:00 |
| **2** | `0 1 * * 1` | Toda segunda-feira às 01:00 |
| **3** | personalizada | Qualquer expressão cron de 5 campos |

#### Opção personalizada — exemplos de expressão cron

```
0 2 * * *       → todos os dias às 02:00
0 3 * * 0,6     → sábado e domingo às 03:00
0 */6 * * *     → a cada 6 horas
0 4 1 * *       → todo dia 1 do mês às 04:00
30 1 * * 1-5    → segunda a sexta às 01:30
```

> O formato é: `minuto hora dia-do-mês mês dia-da-semana`

### O que é gerado

Ao ativar, dois artefatos são criados:

**1. Script `/usr/local/bin/dfe-autoupdate`**

Script executável gerado com a URL do servidor e o ambiente (QA ou PROD) configurados. Ele baixa o `dfe-update.sh` mais recente e executa a atualização.

```bash
# Conteúdo gerado automaticamente
TRACKER_API_URL="https://prod.trackercenter.com.br/app"
DFE_AMBIENTE="PROD"
# ...
bash "$tmpscript" --api-url "$TRACKER_API_URL" --ambiente "$DFE_AMBIENTE" --yes
```

**2. Entrada no crontab do root**

```
0 1 * * * /usr/local/bin/dfe-autoupdate >> /var/log/dfe-autoupdate.log 2>&1 # dfe-autoupdate-managed
```

O log fica em `/var/log/dfe-autoupdate.log`.

### Verificar e desativar

**Verificar status atual** — a tela de configuração exibe o agendamento ativo:

```
==========================================================
           STATUS DO AUTO-UPDATE
==========================================================

  Status      : ATIVO
  Agendamento : 0 1 * * *
  Script      : /usr/local/bin/dfe-autoupdate
  URL         : https://prod.trackercenter.com.br/app
  Ambiente    : PROD
  Log         : /var/log/dfe-autoupdate.log
```

**Verificar via linha de comando:**

```bash
# Ver entrada no crontab
sudo crontab -l | grep dfe-autoupdate

# Acompanhar log de atualizações
sudo tail -f /var/log/dfe-autoupdate.log
```

**Desativar** — escolha a opção **4) Desativar auto-update** no menu. O setup remove a entrada do crontab e pergunta se deseja remover também o script gerado.
