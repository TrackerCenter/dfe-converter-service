<#
Instala o servico DFeConverter usando nssm e garante que o Java usado seja o Java local
incluido na pasta do app (.\java\bin\java.exe). Se o nssm nao existir na pasta do app,
o script tenta baixar automaticamente. Tambem configura AppDirectory, DisplayName,
Description e — opcionalmente — logs (stdout/stderr).

Execute em PowerShell ELEVADO no diretorio do instalador (ou forneca -InstallDir):
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install-service.ps1

Comportamento de logs:
- Por padrao, o redirecionamento de stdout/stderr NAO e configurado (logs DESABILITADOS).
- Para habilitar os logs (quando necessario), passe -EnableAppLogs ao executar o script.

Este script agora pergunta interativamente:
 - escolha entre QA / PROD / Outro
 - solicita JarName, ServiceName e DisplayName (com valores padrao para QA/PROD,
   que podem ser aceitos apenas pressionando Enter)
#>

param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$ConfigName = "config.properties",
    [string]$Description = "J2R Consultoria - Conversao de documentos fiscais para o padrao da reforma tributaria.",
    [string]$NssmVersion = "2.24",
    [switch]$EnableAppLogs
)

# Tentar usar UTF-8 na sessao (inofensivo se nao aplicado)
try { chcp 65001 > $null 2>&1 } catch {}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Log { param($m) "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $m" | Tee-Object -FilePath (Join-Path $InstallDir 'script-install.log') -Append }

# Require elevation
if (-not ([bool](net session 2>$null))) {
    Write-Error "Execute este script em PowerShell 'Como Administrador'."
    exit 1
}

# Normalize InstallDir
$InstallDir = (Resolve-Path -Path $InstallDir).Path

# ---------- Interativo: escolher ambiente e nomes ----------
function Read-EnvChoice {
    while ($true) {
        Write-Host ""
        Write-Host "Escolha o ambiente / versao a instalar:"
        Write-Host "  1) QA"
        Write-Host "  2) PROD"
        Write-Host "  3) Outro (digite valores manualmente)"
        $c = Read-Host "Digite a opcao (1/2/3)"
        switch ($c) {
            '1' { return 'QA' }
            '2' { return 'PROD' }
            '3' { return 'OTHER' }
            default { Write-Host "Opcao invalida. Tente novamente." }
        }
    }
}

function PromptWithDefault([string]$prompt, [string]$default) {
    $r = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $default } else { return $r.Trim() }
}

$envChoice = Read-EnvChoice

if ($envChoice -eq 'QA') {
    $defaultJar = "DFe-Converter-QA.exe"
    $defaultService = "DFeConverterQA"
    $defaultDisplay = "DF-e Converter QA"
    Write-Host "Ambiente selecionado: QA"
    $JarName = PromptWithDefault "Nome do JAR" $defaultJar
    $ServiceName = PromptWithDefault "ServiceName (nome do servico Windows)" $defaultService
    $DisplayName = PromptWithDefault "DisplayName (nome exibido em Services.msc)" $defaultDisplay
}
elseif ($envChoice -eq 'PROD') {
    $defaultJar = "DFe-Converter-PROD.exe"
    $defaultService = "DFeConverterPROD"
    $defaultDisplay = "DF-e Converter PROD"
    Write-Host "Ambiente selecionado: PROD"
    $JarName = PromptWithDefault "Nome do JAR" $defaultJar
    $ServiceName = PromptWithDefault "ServiceName (nome do servico Windows)" $defaultService
    $DisplayName = PromptWithDefault "DisplayName (nome exibido em Services.msc)" $defaultDisplay
}
else {
    Write-Host "Ambiente selecionado: Outro"
    $JarName = Read-Host "Digite o nome do JAR (ex.: DFe-Converter-QA.jar)"
    if ([string]::IsNullOrWhiteSpace($JarName)) { Write-Host "Nome do JAR obrigatorio. Abortando."; exit 2 }
    $ServiceName = Read-Host "Digite o ServiceName (nome do servico Windows)"
    if ([string]::IsNullOrWhiteSpace($ServiceName)) { Write-Host "ServiceName obrigatorio. Abortando."; exit 2 }
    $DisplayName = Read-Host "Digite o DisplayName (nome exibido em Services.msc)"
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { Write-Host "DisplayName obrigatorio. Abortando."; exit 2 }
}

# Derived paths
$javaExe = Join-Path $InstallDir "java\bin\java.exe"
$jarPath = Join-Path $InstallDir $JarName
$configPath = Join-Path $InstallDir $ConfigName
$nssmExe = Join-Path $InstallDir "nssm.exe"
$logsDir = Join-Path $InstallDir "logs"
$stdout = Join-Path $logsDir "stdout.log"
$stderr = Join-Path $logsDir "stderr.log"

Log "Start nssm-install"
Log ("InstallDir: {0}" -f $InstallDir)
Log ("Jar: {0}" -f $jarPath)
Log ("Config: {0}" -f $configPath)
Log ("Local Java: {0}" -f $javaExe)
Log ("ServiceName: {0}" -f $ServiceName)
Log ("DisplayName: {0}" -f $DisplayName)
Log ("Description: {0}" -f $Description)
if ($EnableAppLogs) { Log "Parametro -EnableAppLogs fornecido: logs de stdout/stderr SERÃO configurados." } else { Log "Por padrao logs de stdout/stderr NAO serao configurados (economia de disco)." }

# ---------- Validar JAR ----------
if (-not (Test-Path $jarPath)) {
    Write-Error "JAR nao encontrado: $jarPath"
    Log ("JAR nao encontrado: {0}" -f $jarPath)
    exit 2
}

# Detect local java or fallback to PATH
if (-not (Test-Path $javaExe)) {
    Log ("Java local nao encontrado em {0}. Tentando usar 'java' do PATH." -f $javaExe)
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $javaExe = $cmd.Source } else { $javaExe = $null }
    if (-not $javaExe) {
        Write-Error "java nao encontrado localmente nem no PATH. Coloque a JRE em $InstallDir\java ou instale o JRE no sistema."
        Log "java nao encontrado localmente nem no PATH. Abortando."
        exit 3
    } else {
        Log ("Usando java do PATH: {0}" -f $javaExe)
    }
}

# Create logs dir only if logs are enabled
if ($EnableAppLogs) {
    if (-not (Test-Path $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        Log ("Criada pasta de logs: {0}" -f $logsDir)
    }
} else {
    Log "Nao criarei pasta de logs pois logs estao DESABILITADOS por padrao."
}

# Ensure TLS 1.2 for download
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Download nssm if missing
if (-not (Test-Path $nssmExe)) {
    Log ("nssm.exe nao encontrado em {0}. Tentando baixar nssm-{1}.zip..." -f $InstallDir, $NssmVersion)
    $zipUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
    $tmpZip = Join-Path $env:TEMP "nssm-$NssmVersion.zip"
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        $tmpExtract = Join-Path $env:TEMP "nssm-$NssmVersion"
        if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract }
        Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
        $candidate = Join-Path $tmpExtract "nssm-$NssmVersion\win64\nssm.exe"
        if (-not (Test-Path $candidate)) {
            $candidate = Get-ChildItem -Path $tmpExtract -Recurse -Filter nssm.exe | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($candidate -and (Test-Path $candidate)) {
            Copy-Item -Path $candidate -Destination $nssmExe -Force
            Log ("nssm.exe copiado para {0}" -f $nssmExe)
        } else {
            Write-Error "Nao encontrei nssm.exe dentro do zip. Baixe manualmente e coloque em $InstallDir"
            Log "Falha ao localizar nssm.exe no ZIP."
            exit 4
        }
    } catch {
        Write-Error ("Erro ao baixar/extrair nssm: {0}" -f $_.Exception.Message)
        Log ("Erro ao baixar/extrair nssm: {0}" -f $_.Exception.Message)
        exit 4
    } finally {
        if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
    }
} else {
    Log ("nssm.exe ja presente: {0}" -f $nssmExe)
}

# If service exists, remove to reinstall
try {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Log "Servico existente detectado. Tentando parar e remover..."
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
        & $nssmExe remove $ServiceName confirm | ForEach-Object { Log $_ }
    }
} catch {
    Log ("Aviso ao checar/remover servico existente: {0}" -f $_.Exception.Message)
}

# Build java args for nssm (nssm takes the executable path then arguments)
$escapedJar = '"' + $jarPath + '"'
$escapedConfig = '"' + $configPath + '"'
$javaArgs = "-Dapp.headless=true -Djava.awt.headless=true -jar $escapedJar --sync.config.file=$escapedConfig"

Log ("Instalando servico via nssm: {0} install {1} {2} {3}" -f $nssmExe, $ServiceName, $javaExe, $javaArgs)
& $nssmExe install $ServiceName $javaExe $javaArgs | ForEach-Object { Log $_ }

# Set DisplayName and Description (if provided)
if ($DisplayName) {
    Log ("Definindo DisplayName: {0}" -f $DisplayName)
    & $nssmExe set $ServiceName DisplayName $DisplayName | ForEach-Object { Log $_ }
}
if ($Description) {
    Log ("Definindo Description: {0}" -f $Description)
    & $nssmExe set $ServiceName Description $Description | ForEach-Object { Log $_ }
}

# Configure AppDirectory and logs (logs only if enabled)
& $nssmExe set $ServiceName AppDirectory $InstallDir | ForEach-Object { Log $_ }

if ($EnableAppLogs) {
    & $nssmExe set $ServiceName AppStdout $stdout | ForEach-Object { Log $_ }
    & $nssmExe set $ServiceName AppStderr $stderr | ForEach-Object { Log $_ }
    & $nssmExe set $ServiceName AppRotateFiles 1 | ForEach-Object { Log $_ }
} else {
    Log "AppStdout/AppStderr NAO configurados (logs DESABILITADOS)."
    # Se preferir descartar explicitamente a saida para economizar disco e evitar crescer logs
    # mesmo com AppStdout/AppStderr não configurados, pode usar NUL (descomente abaixo):
    # & $nssmExe set $ServiceName AppStdout NUL | ForEach-Object { Log $_ }
    # & $nssmExe set $ServiceName AppStderr NUL | ForEach-Object { Log $_ }
}

& $nssmExe set $ServiceName Start SERVICE_AUTO_START | ForEach-Object { Log $_ }

# Start service
Log ("Tentando iniciar servico {0} via nssm..." -f $ServiceName)
& $nssmExe start $ServiceName | ForEach-Object { Log $_ }
Start-Sleep -Seconds 3

# Check status
try {
    $s = Get-Service -Name $ServiceName -ErrorAction Stop
    Log ("Service Status: {0}" -f $s.Status)
    if ($s.Status -eq 'Running') {
        Write-Host ("Servico '{0}' instalado e iniciado com sucesso." -f $DisplayName) -ForegroundColor Green
        if ($EnableAppLogs) {
            Write-Host ("Logs do app: {0} e {1}" -f $stdout, $stderr)
        } else {
            Write-Host "Logs de stdout/stderr estao DESABILITADOS por padrao; use .\install-service.ps1 -EnableAppLogs para ativar." -ForegroundColor Yellow
        }
        Log "Servico iniciado com sucesso."
        exit 0
    } else {
        Write-Warning ("Servico instalado mas nao entrou em Running. Status: {0}" -f $s.Status)
        Log ("Servico instalado mas nao entrou em Running. Status: {0}" -f $s.Status)
        if ($EnableAppLogs) {
            Write-Host ("Verifique os arquivos de log em: {0} e {1}" -f $stdout, $stderr) -ForegroundColor Yellow
        } else {
            Write-Host "Logs de stdout/stderr estao DESABILITADOS; consulte event logs do Windows ou reconfigure com -EnableAppLogs." -ForegroundColor Yellow
        }
        exit 5
    }
} catch {
    Write-Error ("Erro ao verificar status do servico: {0}" -f $_.Exception.Message)
    Log ("Erro ao verificar status do servico: {0}" -f $_.Exception.Message)
    exit 6
}
