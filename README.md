# DF-e Converter — Instalar servico (nssm + Java local)

- `install-service.ps1` — instala o servico usando nssm (interativo).
- `uninstall-service.ps1` — desinstala o servico (interativo), preserva pasta `java` local e remove Description automaticamente.

OBS: os scripts foram ajustados para evitar problemas de encoding no console. As mensagens nos scripts utilizam caracteres ASCII (sem acentos). Salve os arquivos `.ps1` em UTF-8 with BOM para melhor compatibilidade.
---

## 1 — Pre-requisitos
- Windows (8/10/11 / Server) com PowerShell (5.1 ou 7+).
- Executar tudo com privilegios de Administrador (UAC).
- JAR/executavel da aplicacao em um diretorio (ex.: `C:\Dfe-Converter\DFe-Converter-QA.jar`).
- (Recomendado) JRE embutida em `C:\Dfe-Converter\java\bin\java.exe` ou `java` disponivel no PATH.
- `nssm.exe` em `C:\Dfe-Converter` ou conectividade para download (o script tenta baixar nssm).
- Salve o `.ps1` em UTF-8 with BOM para evitar problemas de leitura de literais no PowerShell 5.1.

Estrutura exemplificada:
```
C:\Dfe-Converter\
  ├─ DFe-Converter-QA.jar
  ├─ java\bin\java.exe   (opcional)
  └─ nssm.exe            (opcional)
```

---

## 2 — Executar o script PowerShell (modo interativo)

1. Abra PowerShell **Como Administrador**.
2. Navegue ate o diretorio da app:
```powershell
cd C:\Dfe-Converter
```
3. (Opcional) permitir execucao apenas para esta sessao:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```
4. Execute o script de instalacao:
```powershell
.\install-service.ps1
```

Ao executar o script ele eh interativo e ira pedir:
- escolha do ambiente (opcoes: 1 = QA, 2 = PROD, 3 = Outro);
- JarName (opcao com default para QA/PROD);
- ServiceName (opcao com default para QA/PROD);
- DisplayName (opcao com default para QA/PROD).

Exemplo de fluxo (resumo):
- Escolha `1` para QA -> aceita os defaults com Enter, ou edite JarName/ServiceName/DisplayName.
- Escolha `2` para PROD -> aceita defaults PROD ou informe os valores.
- Escolha `3` para Outro -> informe JarName, ServiceName e DisplayName manualmente (obrigatorio).

O script fara:
- validacoes (JAR / Java);
- criara `logs\stdout.log` e `logs\stderr.log`;
- tentara baixar/extrair `nssm` se nao existir localmente;
- instalar o servico via `nssm`;
- definir DisplayName e gravar Description (se especificado) — o Description eh escrito no registro (Unicode-safe);
- configurar AppDirectory, logs, Start=Auto e tentar iniciar o servico;
- registrar a execucao no log `script-install.log` (no InstallDir).

Logs:
- instalacao: `<InstallDir>\script-install.log`
- nssm e output da aplicacao: `<InstallDir>\logs\stdout.log` e `<InstallDir>\logs\stderr.log`

---

## 3 — Exemplo (comportamento automatizado que o script replica)

Com valores hipoteticos:
- InstallDir = `C:\Dfe-Converter`
- Java = `C:\Dfe-Converter\java\bin\java.exe`
- Jar = `DFe-Converter-QA.jar`
- ServiceName = `DFeConverterQA`

Comandos equivalentes (para referencia):

```powershell
# instalar via nssm (executavel + argumentos)
"C:\Dfe-Converter\nssm.exe" install DFeConverterQA "C:\Dfe-Converter\java\bin\java.exe" "-Dapp.headless=true -Djava.awt.headless=true -jar ""C:\Dfe-Converter\DFe-Converter-QA.jar"" --sync.config.file=""C:\Dfe-Converter\config.properties"""

# definir DisplayName
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA DisplayName "DF-e Converter QA"

# configurar diretorio da app e logs
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppDirectory "C:\Dfe-Converter"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppStdout "C:\Dfe-Converter\logs\stdout.log"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppStderr "C:\Dfe-Converter\logs\stderr.log"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppRotateFiles 1
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA Start SERVICE_AUTO_START

# iniciar o servico
"C:\Dfe-Converter\nssm.exe" start DFeConverterQA
```

---

## 4 — Configurar Description com seguranca (Unicode-safe)

O script grava Description diretamente no registro do servico (HKLM) para evitar problemas de encoding pela CLI. Se quiser definir manualmente:

```powershell
$ServiceName = "DFeConverterQA"
$Description = "J2R Consultoria - Servico de conversao de documentos fiscais para o padrao da reforma tributaria."
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

# criar chave se necessario (deve existir apos nssm install)
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

# gravar Description (Unicode)
Set-ItemProperty -Path $regPath -Name Description -Value $Description -ErrorAction Stop

# conferir
Get-ItemProperty -Path $regPath -Name Description
```

Se preferir usar `sc.exe`:
```powershell
sc.exe description DFeConverterQA "J2R Consultoria - Servico de conversao..."
```
(atenção: `sc.exe` pode apresentar problemas de encoding dependendo do console).

---

## 5 — Verificacao e diagnostico

- Ver o status do servico:
```powershell
Get-Service -Name DFeConverterQA | Format-List *
sc query DFeConverterQA
```

- Ver processo Java e linha de comando:
```powershell
Get-CimInstance Win32_Process -Filter "name='java.exe'" |
  Where-Object { $_.CommandLine -match "DFe-Converter-QA" } |
  Select-Object ProcessId, CommandLine | Format-List
```

- Ler logs criados por nssm:
```powershell
Get-Content -Path "C:\Dfe-Converter\logs\stdout.log" -Tail 200 -Encoding UTF8
Get-Content -Path "C:\Dfe-Converter\logs\stderr.log" -Tail 200 -Encoding UTF8
```

- Procurar logs da aplicacao:
```powershell
Get-ChildItem -Path "C:\Dfe-Converter" -Recurse -Filter *.log |
  Sort-Object LastWriteTime -Descending | Select-Object -First 20 FullName, LastWriteTime
```

- Testar endpoint HTTP (se aplicavel):
```powershell
Invoke-WebRequest -Uri http://localhost:8080/actuator/health -UseBasicParsing -ErrorAction SilentlyContinue
```

- Gerar thread dump (se tiver jstack/jcmd):
```powershell
"C:\Dfe-Converter\java\bin\jstack" <PID> > "C:\Dfe-Converter\jstack.txt"
```

---

## 6 — Desinstalar o servico (interativo)

Utilize `uninstall-service.ps1` (script interativo) ou, manualmente, os comandos abaixo.

Principais diferencas do script de desinstalacao atual:
- O script preserva sempre a pasta `java` local (nao sera removida).
- O script remove automaticamente o campo `Description` do registro quando o servico eh removido.
- O script pergunta se deve remover `nssm.exe` do diretorio da aplicacao (sim/nao).
- Logs de desinstalacao: `<InstallDir>\uninstall-nssm-localjava.log`.

Comandos manuais equivalentes:

Via nssm:
```powershell
"C:\Dfe-Converter\nssm.exe" stop DFeConverterQA
"C:\Dfe-Converter\nssm.exe" remove DFeConverterQA confirm
```

Via sc:
```powershell
sc stop DFeConverterQA
sc delete DFeConverterQA
```

Remover Description do registro (o script faz isso automaticamente):
```powershell
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DFeConverterQA" -Name Description -ErrorAction SilentlyContinue
```

---

## 7 — Procedimento manual completo (se NAO for usar o script)

1. Copie sua aplicacao e `nssm.exe` para a pasta da app, por exemplo `C:\Dfe-Converter`.
2. Abra PowerShell **Como Administrador**.
3. Crie a pasta de logs:
```powershell
New-Item -Path "C:\Dfe-Converter\logs" -ItemType Directory -Force
```
4. Instale o servico com nssm (exemplo):
```powershell
$java = "C:\Dfe-Converter\java\bin\java.exe"
$jar  = "C:\Dfe-Converter\DFe-Converter-QA.jar"
$args = '-Dapp.headless=true -Djava.awt.headless=true -jar "' + $jar + '" --sync.config.file="C:\Dfe-Converter\config.properties"'
"C:\Dfe-Converter\nssm.exe" install DFeConverterQA $java $args
```
5. Configure DisplayName e AppDirectory / logs:
```powershell
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA DisplayName "DF-e Converter QA"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppDirectory "C:\Dfe-Converter"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppStdout "C:\Dfe-Converter\logs\stdout.log"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppStderr "C:\Dfe-Converter\logs\stderr.log"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppRotateFiles 1
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA Start SERVICE_AUTO_START
```
6. Inicie o servico:
```powershell
"C:\Dfe-Converter\nssm.exe" start DFeConverterQA
```
7. Verifique logs e status (veja a secao 5).

---

## 8 — Troubleshooting rapido
- Acesso negado: execute PowerShell como Administrador.
- Script nao encontrou `java`: coloque JRE em `.\java\bin\java.exe` ou instale Java no sistema (`where java`).
- `nssm.exe` ausente/falha: baixe manualmente de https://nssm.cc e coloque em `InstallDir`.
- Texto com acentos corrompido em consoles antigos: salve `.ps1` em UTF-8 with BOM; se persistir, remova acentos nos textos do script (os scripts fornecidos usam mensagens ASCII).
- Servico entra em Running mas app nao responde: ver `stderr.log`/`stdout.log` e logs da app; verificar configuracao de porta.
- Para detalhes, consulte `script-install.log` e `uninstall-nssm-localjava.log` no `InstallDir`.

---

## 9 — Checklist resumido
- [ ] Copiar JAR para `C:\Dfe-Converter`
- [ ] (Opcional) Copiar JRE para `C:\Dfe-Converter\java\bin\java.exe`
- [ ] Colocar `nssm.exe` em `C:\Dfe-Converter` (ou permitir download pelo script)
- [ ] Abrir PowerShell como Administrador
- [ ] Salvar `.ps1` em UTF-8 with BOM
- [ ] Executar `.\install-service.ps1` e responder as perguntas interativas
- [ ] Verificar status e logs

---
