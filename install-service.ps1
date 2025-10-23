<#
Instala o serviço DFeConverter usando nssm e garante que o Java usado seja o Java local
incluído na pasta do app (.\java\bin\java.exe). Se o nssm não existir na pasta do app,
o script tenta baixar automaticamente. Também configura AppDirectory e logs.

Execute em PowerShell ELEVADO no diretório do instalador (ou forneça -InstallDir):
Set-ExecutionPolicy Bypass -Scope Process -Force
.\instalar-service-nssm-localjava.ps1

Parâmetros opcionais:
  -InstallDir   Diretório onde está a app (padrão = pasta do script)
  -JarName      Nome do JAR (padrão DFe-Converter-QA.jar)
  -ConfigName   Nome do arquivo de config (padrão config.properties)
  -ServiceName  Nome do serviço Windows (padrão DFeConverter)
  -DisplayName  Nome exibido do serviço (padrão "DF-e Converter")
#>

param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$JarName = "DFe-Converter-QA.exe",
    [string]$ConfigName = "config.properties",
    [string]$ServiceName = "DFeConverter",
    [string]$DisplayName = "DF-e Converter",
    [string]$NssmVersion = "2.24"
)

function Log { param($m) "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $m" | Tee-Object -FilePath (Join-Path $InstallDir 'install-nssm-localjava.log') -Append }

# ===== Auto-elevate (PowerShell 5.1+ / 7) =====
$currIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = (if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path })
    $args = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', $scriptPath
    )
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) {
    Start-Process -FilePath $pwshCmd.Source -ArgumentList $args -Verb RunAs
    } else {
    $psCmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($psCmd) {
    Start-Process -FilePath $psCmd.Source -ArgumentList $args -Verb RunAs
    } else {
    Write-Error "Nenhum executável PowerShell encontrado para relançar com privilégios."
    exit 1
    }
    }
    exit
}
# =============================================

# Normalize paths
$InstallDir = (Resolve-Path -Path $InstallDir).Path
$javaExe = Join-Path $InstallDir "java\bin\java.exe"
$jarPath = Join-Path $InstallDir $JarName
$configPath = Join-Path $InstallDir $ConfigName
$nssmExe = Join-Path $InstallDir "nssm.exe"
$logsDir = Join-Path $InstallDir "logs"
$stdout = Join-Path $logsDir "stdout.log"
$stderr = Join-Path $logsDir "stderr.log"

Log "Start install-nssm-localjava"
Log "InstallDir: $InstallDir"
Log "Jar: $jarPath"
Log "Config: $configPath"
Log "Local Java: $javaExe"

if (-not (Test-Path $jarPath)) {
    Write-Error "JAR não encontrado: $jarPath"
    Log "JAR não encontrado: $jarPath"
    exit 2
}
# Detect local java or fallback to PATH
if (-not (Test-Path $javaExe)) {
    Log "Java local não encontrado em $javaExe. Tentando usar 'java' do PATH (não recomendado)."
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $javaExe = $cmd.Source } else { $javaExe = $null }
    if (-not $javaExe) {
        Write-Error "java não encontrado localmente nem no PATH. Coloque a JRE em $InstallDir\java ou instale o JRE no sistema."
        Log "java não encontrado localmente nem no PATH. Abortando."
        exit 3
    } else {
        Log "Usando java do PATH: $javaExe"
    }
}

# Create logs dir
if (-not (Test-Path $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    Log "Criada pasta de logs: $logsDir"
}

# Ensure TLS 1.2 for download
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Download nssm if missing
if (-not (Test-Path $nssmExe)) {
    Log "nssm.exe não encontrado em $InstallDir. Tentando baixar nssm-$NssmVersion.zip..."
    $zipUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
    $tmpZip = Join-Path $env:TEMP "nssm-$NssmVersion.zip"
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        $tmpExtract = Join-Path $env:TEMP "nssm-$NssmVersion"
        if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract }
        Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
        # Prefer win64 build
        $candidate = Join-Path $tmpExtract "nssm-$NssmVersion\win64\nssm.exe"
        if (-not (Test-Path $candidate)) {
            $candidate = Get-ChildItem -Path $tmpExtract -Recurse -Filter nssm.exe | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($candidate -and (Test-Path $candidate)) {
            Copy-Item -Path $candidate -Destination $nssmExe -Force
            Log "nssm.exe copiado para $nssmExe"
        } else {
            Write-Error "Não encontrei nssm.exe dentro do zip. Baixe manualmente e coloque em $InstallDir"
            Log "Falha ao localizar nssm.exe no ZIP."
            exit 4
        }
    } catch {
        Write-Error "Erro ao baixar/extrair nssm: $($_.Exception.Message)"
        Log "Erro ao baixar/extrair nssm: $($_.Exception.Message)"
        exit 4
    } finally {
        if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
    }
} else {
    Log "nssm.exe já presente: $nssmExe"
}

# If service exists, remove to reinstall
try {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Log "Serviço existente detectado. Tentando parar e remover..."
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
        & $nssmExe remove $ServiceName confirm | ForEach-Object { Log $_ }
    }
} catch {
    Log "Aviso ao checar/remover serviço existente: $($_.Exception.Message)"
}

# Build java args for nssm (nssm takes the executable path then arguments)
$escapedJar = '"' + $jarPath + '"'
$escapedConfig = '"' + $configPath + '"'
$javaArgs = "-Dapp.headless=true -Djava.awt.headless=true -jar $escapedJar --sync.config.file=$escapedConfig"

Log "Instalando serviço via nssm: $nssmExe install $ServiceName $javaExe $javaArgs"
# Install (pass the args as a single string; nssm will parse)
& $nssmExe install $ServiceName $javaExe $javaArgs | ForEach-Object { Log $_ }

# Configure AppDirectory and logs
& $nssmExe set $ServiceName AppDirectory $InstallDir | ForEach-Object { Log $_ }
& $nssmExe set $ServiceName AppStdout $stdout | ForEach-Object { Log $_ }
& $nssmExe set $ServiceName AppStderr $stderr | ForEach-Object { Log $_ }
# Use a supported rotation parameter
& $nssmExe set $ServiceName AppRotateFiles 1 | ForEach-Object { Log $_ }
# Set auto start
& $nssmExe set $ServiceName Start SERVICE_AUTO_START | ForEach-Object { Log $_ }

# Start service
Log "Tentando iniciar serviço $ServiceName via nssm..."
& $nssmExe start $ServiceName | ForEach-Object { Log $_ }
Start-Sleep -Seconds 3

# Check status
try {
    $s = Get-Service -Name $ServiceName -ErrorAction Stop
    Log "Service Status: $($s.Status)"
    if ($s.Status -eq 'Running') {
        Write-Host "Serviço '$DisplayName' instalado e iniciado com sucesso." -ForegroundColor Green
        Write-Host "Logs do app: $stdout e $stderr"
        Log "Serviço iniciado com sucesso."
        exit 0
    } else {
        Write-Warning "Serviço instalado mas não entrou em Running. Status: $($s.Status)"
        Log "Serviço instalado mas não entrou em Running. Status: $($s.Status)"
        Write-Host "Verifique os arquivos de log em: $stdout e $stderr" -ForegroundColor Yellow
        exit 5
    }
} catch {
    Write-Error "Erro ao verificar status do serviço: $($_.Exception.Message)"
    Log "Erro ao verificar status do serviço: $($_.Exception.Message)"
    exit 6
}
