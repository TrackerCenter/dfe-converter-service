<#
dfe-setup.ps1 - Menu interativo para instalar / remover / reinstalar (Windows)
Comportamento:
 - Baixa scripts diretamente de:
   https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts
 - Salva temporariamente em $env:TEMP com o mesmo nome (ex.: dfe-install.ps1, dfe-bootstrap.sh)
 - Garante que arquivos .ps1 possuem extensao adequada para execuçao com -File
 - Por segurança NaO executa automaticamente o dfe-bootstrap.sh no Windows,
   a menos que a variável de ambiente RUN_LINUX_BOOTSTRAP=1 seja definida.
 - Remove arquivos temporários após execuçao.
Execute em PowerShell como Administrador.
#>
[CmdletBinding()]
param()

# ---------- Config ----------
$RawBase = "https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts"
$BootstrapName     = 'dfe-bootstrap.sh'
$InstallScriptName = 'dfe-install.ps1'
$UninstallScriptName = 'dfe-uninstall.ps1'

# ---------- Resolve ScriptDir de forma robusta ----------
$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptDir = (Get-Location).Path
    $RunningInline = $true
} else {
    $ScriptDir = Split-Path -Parent $ScriptPath
    $RunningInline = $false
}

function Ensure-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Reexecutando em modo Administrador..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
        if ($pwsh) { $psi.FileName = $pwsh.Source } else { $psi.FileName = (Get-Command powershell).Source }
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $psi.Verb = "runas"
        try { [System.Diagnostics.Process]::Start($psi) | Out-Null; exit } catch { Write-Error "Falha ao elevar."; exit 1 }
    }
}

function Download-ScriptToTemp {
    param([string]$Name)

    $url = "$RawBase/$Name"
    $dest = Join-Path $env:TEMP $Name

    try {
        Write-Verbose "Baixando $url -> $dest"
        # Force overwrite if exists
        if (Test-Path $dest) { Remove-Item -Force $dest -ErrorAction SilentlyContinue }
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        return $dest
    } catch {
        Write-Warning "Falha ao baixar $url : $($_.Exception.Message)"
        if (Test-Path $dest) { Remove-Item -Force $dest -ErrorAction SilentlyContinue }
        return $null
    }
}

function Convert-WindowsPathToBash($winPath, $bashPath) {
    # Converte "C:\Users\..." -> "/c/Users/..." (funciona para Git Bash / MSYS)
    if ($winPath -match '^[A-Za-z]:(\\|/)') {
        $drive = $winPath.Substring(0,1).ToLower()
        $rest = $winPath.Substring(2) -replace '\\','/'
        return "/$drive/$rest"
    } else {
        return ($winPath -replace '\\','/')
    }
}

function Run-LinuxBootstrapSafe {
    param([string]$BootstrapPath)
    # Por padrao NaO executamos .sh no Windows; usar RUN_LINUX_BOOTSTRAP=1 se realmente deseja.
    if ($env:RUN_LINUX_BOOTSTRAP -ne '1') {
        Write-Host "Bootstrap presente em $BootstrapPath, mas por padrao NaO executarei scripts .sh no Windows."
        Write-Host 'Se realmente deseja executar o bootstrap (requer bash configurado), defina:'
        Write-Host '  $env:RUN_LINUX_BOOTSTRAP = "1"'
        return $false
    }

    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bashCmd) {
        Write-Warning "bash nao encontrado no PATH. Instale Git Bash / WSL / MSYS para executar scripts .sh no Windows."
        return $false
    }

    $posix = Convert-WindowsPathToBash $BootstrapPath $bashCmd.Path

    try {
        if ($env:AUTO_INSTALL_JQ -eq '1') {
            Write-Host "AUTO_INSTALL_JQ=1 detectado: executando bootstrap sem prompt (--yes)..."
            & $bashCmd.Path $posix --yes
        } else {
            Write-Host "Executando bootstrap (pode pedir confirmaçao para instalar dependências)..."
            & $bashCmd.Path $posix
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Bootstrap retornou código $LASTEXITCODE"
            return $false
        }
        return $true
    } catch {
        Write-Warning "Falha ao executar bootstrap via bash: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-TempPS1 {
    param([string]$TempPath)
    if (-not (Test-Path $TempPath)) { throw "Arquivo PS1 nao encontrado: $TempPath" }
    try {
        Write-Host "Executando $TempPath"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $TempPath
    } finally {
        # cleanup
        if (Test-Path $TempPath) { Remove-Item -Force $TempPath -ErrorAction SilentlyContinue }
    }
}

# --------- Normalizer: remove acentos e caracteres especiais ----------
function Normalize-ServiceName {
    param([string]$name)
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }

    # Decompose (FormD) and remove non-spacing marks (diacritics)
    $nf = [System.Text.NormalizationForm]::FormD
    $decomposed = $name.Normalize($nf)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $decomposed.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    $recomposed = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)

    # Replace whitespace with nothing and remove any character not in A-Z a-z 0-9 - _
    $noSpace = $recomposed -replace '\s+', ''
    $chars = $noSpace.ToCharArray() | ForEach-Object {
        if ($_ -match '[A-Za-z0-9\-_]') { $_ } else { '' }
    }
    return -join $chars
}

function Read-ServiceChoice {
    while ($true) {
    Write-Host ""
    Write-Host "Escolha o serviço para checar:"
    Write-Host "  1) DFeConverterQA"
    Write-Host "  2) DFeConverterPROD"
    Write-Host "
