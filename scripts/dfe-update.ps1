# dfe-update.ps1 - Verifica e aplica atualização do DF-e Converter (Windows)
# Requer: PowerShell 5.1+ (nativo no Windows)
param(
    [Parameter(Mandatory=$true)]
    [string]$ApiUrl,
    [string]$StateFile = "",
    [string]$InstallDir = "",
    [string]$Ambiente = "QA",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ApiUrl = $ApiUrl.TrimEnd('/')

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "$ts [$Level] $Message"
}

# Find state file
function Find-StateFile {
    if ($StateFile) { return $StateFile }
    if ($InstallDir) { return Join-Path $InstallDir ".dfe-setup.env" }
    $candidates = @(
        "C:\DFE_CONVERTER_QA\.dfe-setup.env",
        "C:\DFE_CONVERTER_PROD\.dfe-setup.env",
        "$env:ProgramFiles\DFE_CONVERTER_QA\.dfe-setup.env"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return ""
}

# Read state file key=value
function Read-State {
    param([string]$Key, [string]$File)
    if (-not (Test-Path $File)) { return "" }
    $line = Get-Content $File | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^${Key}=", "") }
    return ""
}

# Write/update state file
function Write-State {
    param([string]$Key, [string]$Value, [string]$File)
    if (-not (Test-Path $File)) { New-Item -ItemType File -Path $File -Force | Out-Null }
    $content = Get-Content $File -ErrorAction SilentlyContinue
    if ($content -match "^${Key}=") {
        $content = $content -replace "^${Key}=.*", "${Key}=${Value}"
    } else {
        $content += "${Key}=${Value}"
    }
    Set-Content $File $content
}

$sf = Find-StateFile
if (-not $sf -or -not (Test-Path $sf)) {
    Write-Log "Arquivo de estado não encontrado. Use -StateFile ou -InstallDir." "ERRO"
    exit 1
}

Write-Log "Estado: $sf"

$currentVersao   = Read-State "DFE_VERSAO" $sf
$currentChecksum = Read-State "DFE_CHECKSUM_SHA256" $sf
$installDirActual = Read-State "DFE_INSTALL_DIR" $sf
$serviceName     = Read-State "DFE_SERVICE_NAME" $sf
$jarName         = Read-State "DFE_JAR_NAME" $sf
$ambienteActual  = if ($Ambiente) { $Ambiente.ToUpper() } else { (Read-State "DFE_AMBIENTE" $sf).ToUpper() }
if (-not $ambienteActual) { $ambienteActual = "QA" }

Write-Log "Instalação: service=$serviceName | versão=$currentVersao | ambiente=$ambienteActual"

# Fetch version info
$infoUrl = "$ApiUrl/api/v1/dfe-converter/versoes/latest/info?ambiente=$ambienteActual&tipo=EXE"
Write-Log "Consultando: $infoUrl"

try {
    $infoText = (Invoke-WebRequest -Uri $infoUrl -UseBasicParsing).Content
} catch {
    Write-Log "Falha ao consultar versão: $_" "ERRO"
    exit 1
}

# Parse KEY=VALUE response
function Parse-InfoValue {
    param([string]$Key, [string]$Text)
    $line = $Text -split "`n" | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^${Key}=", "").Trim() }
    return ""
}

$remoteVersao   = Parse-InfoValue "DFE_VERSAO" $infoText
$remoteChecksum = Parse-InfoValue "DFE_CHECKSUM_SHA256" $infoText
$remoteNome     = Parse-InfoValue "DFE_NOME_ARQUIVO" $infoText
$remoteTamanho  = Parse-InfoValue "DFE_TAMANHO_BYTES" $infoText
$remoteData     = Parse-InfoValue "DFE_DATA_UPLOAD" $infoText

if (-not $remoteVersao) {
    Write-Log "Resposta inválida do servidor." "ERRO"
    exit 1
}

Write-Log "Remoto: $remoteVersao | Instalado: $(if ($currentVersao) { $currentVersao } else { 'nenhum' })"

if ($remoteVersao -eq $currentVersao -and $currentVersao -and $remoteChecksum -eq $currentChecksum -and $currentChecksum) {
    Write-Log "Já está na versão mais recente ($remoteVersao). Nenhuma atualização necessária."
    exit 0
}

$tamMB = if ($remoteTamanho) { [math]::Round([long]$remoteTamanho / 1MB, 1) } else { "?" }
Write-Host ""
Write-Host "=========================================================="
Write-Host "              ATUALIZAÇÃO DISPONÍVEL"
Write-Host "=========================================================="
Write-Host ""
Write-Host "  Versão instalada:   $(if ($currentVersao) { $currentVersao } else { 'nenhuma' })"
Write-Host "  Versão disponível:  $remoteVersao"
Write-Host "  Arquivo:            $(if ($remoteNome) { $remoteNome } else { "DFe-Converter-$ambienteActual.exe" })"
Write-Host "  Tamanho:            $tamMB MB"
Write-Host "  Data:               $remoteData"
Write-Host ""

if (-not $Yes) {
    $yn = Read-Host "Deseja atualizar? (y/N)"
    if ($yn -notmatch "^[yY]") {
        Write-Log "Atualização cancelada."
        exit 0
    }
}

# Download new EXE
$downloadUrl = "$ApiUrl/api/v1/dfe-converter/versoes/latest/download?ambiente=$ambienteActual&tipo=EXE"
$tmpFile = Join-Path $env:TEMP "dfe-converter-update-$([System.IO.Path]::GetRandomFileName()).exe"
Write-Log "Baixando: $downloadUrl"

try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpFile -UseBasicParsing
} catch {
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    Write-Log "Falha ao baixar: $_" "ERRO"
    exit 1
}

# Validate checksum
if ($remoteChecksum) {
    Write-Log "Validando checksum SHA-256..."
    $hash = (Get-FileHash -Path $tmpFile -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $remoteChecksum) {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        Write-Log "Checksum inválido! Esperado: $remoteChecksum | Obtido: $hash" "ERRO"
        exit 1
    }
    Write-Log "Checksum OK"
}

$destExe = Join-Path $installDirActual $jarName

# Stop service
Write-Log "Parando service: $serviceName"
try {
    $nssmPath = "$installDirActual\nssm.exe"
    if (Test-Path $nssmPath) {
        & $nssmPath stop $serviceName confirm 2>$null
    } else {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Log "Aviso ao parar service: $_" "WARN" }

Start-Sleep -Seconds 2

# Backup current
if (Test-Path $destExe) {
    $bak = "${destExe}.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Log "Backup: $destExe -> $bak"
    Copy-Item $destExe $bak
}

# Replace
Write-Log "Substituindo: $destExe"
Move-Item $tmpFile $destExe -Force

# Restart service
Write-Log "Iniciando service: $serviceName"
try {
    $nssmPath = "$installDirActual\nssm.exe"
    if (Test-Path $nssmPath) {
        & $nssmPath start $serviceName
    } else {
        Start-Service -Name $serviceName
    }
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Log "Service iniciado com sucesso."
    } else {
        Write-Log "Verifique o status do service manualmente." "WARN"
    }
} catch { Write-Log "Aviso ao iniciar service: $_" "WARN" }

# Update state
Write-State "DFE_VERSAO" $remoteVersao $sf
Write-State "DFE_CHECKSUM_SHA256" $remoteChecksum $sf
Write-State "DFE_INSTALLED_AT" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) $sf

Write-Log "Atualização concluída: $currentVersao -> $remoteVersao"
exit 0
