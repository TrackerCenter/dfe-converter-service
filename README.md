# DF-e Converter — Instalar serviço (nssm + Java local)

## 1 — Pré-requisitos
- Windows (8/10/11 / Server) com PowerShell (5.1 ou 7+).
- Executar tudo com privilégios de Administrador (UAC).
- JAR/executável da aplicação em um diretório (ex.: `C:\Dfe-Converter\DFe-Converter-QA.jar`).
- (Recomendado) JRE embutida em `C:\Dfe-Converter\java\bin\java.exe` ou `java` disponível no PATH.
- `nssm.exe` em `C:\Dfe-Converter` ou conectividade para download (o script tenta baixar `nssm`).
- Salve o `.ps1` em UTF-8 com BOM para preservar acentuação na Description (PowerShell 5.1).

Estrutura exemplificada:
```
C:\Dfe-Converter\
  ├─ DFe-Converter-QA.jar
  ├─ java\bin\java.exe   (opcional)
  └─ nssm.exe            (opcional)
```

---

## 2 — Executar o script PowerShell (modo automático)

1. Abra PowerShell **Como Administrador**.
2. Vá para o diretório da app:
```powershell
cd C:\Dfe-Converter
```
3. (Opcional) permitir execução apenas para esta sessão:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```
4. Execute o script (nome esperado: `install-service.ps1`):
```powershell
.\install-service.ps1
```

### Exemplo com parâmetros (personalizado)
```powershell
.\install-service.ps1 `
  -InstallDir "C:\Dfe-Converter" `
  -JarName "DFe-Converter-QA.jar" `
  -ConfigName "config.properties" `
  -ServiceName "DFeConverterQA" `
  -DisplayName "DF-e Converter QA" `
  -Description "J2R Consultoria - Conversao de documentos fiscais para o padrao da reforma tributaria." `
  -NssmVersion "2.24"
```

O script fará:
- Verificações (JAR / Java).
- Criará `logs\stdout.log` e `logs\stderr.log`.
- Baixará/extrairá `nssm` (se não existir).
- Instalar o serviço via `nssm`.
- Definirá DisplayName e gravará Description no registro (Unicode-safe).
- Configurará AppDirectory, logs, Start=Auto e tentará iniciar.

---

## 3 — Exemplo dos comandos que o script executa (para referência)

Substitua caminhos/nome do serviço conforme seu ambiente:

```powershell
# instalar via nssm (executável, depois argumentos)
"C:\Dfe-Converter\nssm.exe" install DFeConverterQA "C:\Dfe-Converter\java\bin\java.exe" "-Dapp.headless=true -Djava.awt.headless=true -jar ""C:\Dfe-Converter\DFe-Converter-QA.jar"" --sync.config.file=""C:\Dfe-Converter\config.properties"""

# definir DisplayName
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA DisplayName "DF-e Converter QA"

# configurar diretório da app e logs
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppDirectory "C:\Dfe-Converter"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppStdout "C:\Dfe-Converter\logs\stdout.log"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppStderr "C:\Dfe-Converter\logs\stderr.log"
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA AppRotateFiles 1
"C:\Dfe-Converter\nssm.exe" set DFeConverterQA Start SERVICE_AUTO_START

# iniciar o serviço
"C:\Dfe-Converter\nssm.exe" start DFeConverterQA
```

---

## 4 — Configurar Description com segurança (Unicode-safe)
Para evitar problemas de encoding ao passar acentos via CLI, grave a descrição no registro:

```powershell
$ServiceName = "DFeConverterQA"
$Description = "J2R Consultoria - Serviço de conversão de documentos fiscais para o padrão da reforma tributária."
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

# criar chave se necessário (deve existir após nssm install)
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

# gravar Description (Unicode)
Set-ItemProperty -Path $regPath -Name Description -Value $Description -ErrorAction Stop

# conferir
Get-ItemProperty -Path $regPath -Name Description
```

Se preferir `sc.exe` (pode ter problemas de encoding dependendo do ambiente):
```powershell
sc.exe description DFeConverterQA "J2R Consultoria - Serviço de conversão de documentos fiscais ..."
```

---

## 5 — Verificação e diagnóstico

- Ver o status do serviço:
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

- Procurar logs da aplicação:
```powershell
Get-ChildItem -Path "C:\Dfe-Converter" -Recurse -Filter *.log |
  Sort-Object LastWriteTime -Descending | Select-Object -First 20 FullName, LastWriteTime
```

- Testar endpoint HTTP (se aplicável):
```powershell
Invoke-WebRequest -Uri http://localhost:8080/actuator/health -UseBasicParsing -ErrorAction SilentlyContinue
```

- Gerar thread dump (se tiver jstack/jcmd):
```powershell
"C:\Dfe-Converter\java\bin\jstack" <PID> > "C:\Dfe-Converter\jstack.txt"
```

---

## 6 — Remover/desinstalar o serviço

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

Remover Description do registro (opcional):
```powershell
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DFeConverterQA" -Name Description -ErrorAction SilentlyContinue
```

---

## 7 — Procedimento manual completo (se NÃO for usar o script e já tiver nssm.exe + jar/exe)

1. Copie sua aplicação e `nssm.exe` para a pasta da app, por exemplo `C:\Dfe-Converter`.
2. Abra PowerShell **Como Administrador**.
3. Crie a pasta de logs:
```powershell
New-Item -Path "C:\Dfe-Converter\logs" -ItemType Directory -Force
```
4. Instale o serviço com nssm (exemplo):
```powershell
# argumento da JVM (observe as aspas internas)
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
6. Defina a descrição com segurança (registro):
```powershell
$desc = "J2R Consultoria - Serviço de conversão de documentos fiscais para o padrão da reforma tributária."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DFeConverterQA" -Name Description -Value $desc
```
7. Inicie o serviço:
```powershell
"C:\Dfe-Converter\nssm.exe" start DFeConverterQA
```
8. Verifique logs e status (ver seção 5 para comandos).

---

## 8 — Troubleshooting rápido
- Erro “Acesso negado”: abra PowerShell como Administrador (UAC).
- Script não encontrou `java`: coloque JRE em `.\java\bin\java.exe` ou instale Java e garanta `where java` resolve.
- `nssm.exe` falhou/ausente: baixe manualmente de https://nssm.cc e coloque em `InstallDir`.
- Texto com acentos na Description corrompido: salve `.ps1` em UTF‑8 com BOM e use `Set-ItemProperty` no registro.
- Serviço entra em Running mas app não responde: ver `stderr.log`/`stdout.log` e logs da app; verificar porta configurada.
- Para detalhes, consulte `nssm-install.log` gerado pelo script.

---
