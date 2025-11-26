<#
dfe-setup.ps1 - Menu interativo para instalar / remover / reinstalar (Windows)
Versao: 1.0.0
Comportamento:
 - Baixa scripts diretamente de:
   https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts
 - Salva temporariamente em $env:TEMP com o mesmo nome (ex.: dfe-install.ps1, dfe-bootstrap.sh)
 - Garante que arquivos . ps1 possuem extensao adequada para execuçao com -File
 - Por segurança NAO executa automaticamente o dfe-bootstrap.sh no Windows,
   a menos que a variável de ambiente RUN_LINUX_BOOTSTRAP=1 seja definida.
 - Remove arquivos temporários após execuçao.
Execute em PowerShell como Administrador.
#>
[CmdletBinding()]
param()

# ---------- Versao do Script ----------
$SCRIPT_VERSION = "1.0.0"

# ---------- Config ----------
$RawBase = "https://raw.githubusercontent. com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts"
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

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                                                        ║" -ForegroundColor Cyan
    Write-Host "║           DF-e Converter - Setup (Windows)            ║" -ForegroundColor Cyan
    Write-Host "║                                                        ║" -ForegroundColor Cyan
    Write-Host "║                   Versao: $SCRIPT_VERSION                      ║" -ForegroundColor Cyan
    Write-Host "║                                                        ║" -ForegroundColor Cyan
    Write-Host "║              J2R Consultoria Informatica               ║" -ForegroundColor Cyan
    Write-Host "║                                                        ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Ensure-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Reexecutando em modo Administrador..." -ForegroundColor Yellow
        $psi = New-Object System. Diagnostics.ProcessStartInfo
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
        if ($pwsh) { $psi. FileName = $pwsh.Source } else { $psi.FileName = (Get-Command powershell). Source }
        $psi. Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $psi. Verb = "runas"
        try { [System.Diagnostics.Process]::Start($psi) | Out-Null; exit } catch { Write-Error "Falha ao elevar. "; exit 1 }
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
        $drive = $winPath. Substring(0,1). ToLower()
        $rest = $winPath.Substring(2) -replace '\\','/'
        return "/$drive$rest"
    } else {
        return ($winPath -replace '\\','/')
    }
}

function Run-LinuxBootstrapSafe {
    param([string]$BootstrapPath)
    # Por padrao NAO executamos . sh no Windows; usar RUN_LINUX_BOOTSTRAP=1 se realmente deseja.
    if ($env:RUN_LINUX_BOOTSTRAP -ne '1') {
        Write-Host "Bootstrap presente em $BootstrapPath, mas por padrao NAO executarei scripts .sh no Windows." -ForegroundColor Yellow
        Write-Host 'Se realmente deseja executar o bootstrap (requer bash configurado), defina:'
        Write-Host '  $env:RUN_LINUX_BOOTSTRAP = "1"'
        return $false
    }

    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bashCmd) {
        Write-Warning "bash nao encontrado no PATH.  Instale Git Bash / WSL / MSYS para executar scripts .sh no Windows."
        return $false
    }

    $posix = Convert-WindowsPathToBash $BootstrapPath $bashCmd. Path

    try {
        if ($env:AUTO_INSTALL_JQ -eq '1') {
            Write-Host "AUTO_INSTALL_JQ=1 detectado: executando bootstrap sem prompt (--yes)..."
            & $bashCmd. Path $posix --yes
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
    $decomposed = $name. Normalize($nf)
    $sb = New-Object System. Text.StringBuilder
    foreach ($c in $decomposed. ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    $recomposed = $sb.ToString(). Normalize([System.Text.NormalizationForm]::FormC)

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
        Write-Host "Escolha o servico para checar:"
        Write-Host "  1) DFeConverterQA"
        Write-Host "  2) DFeConverterPROD"
        Write-Host "  3) Outro (digite o nome do servico)"
        $choice = Read-Host "Digite a opcao (1/2/3)"
        switch ($choice) {
            '1' { return 'DFeConverterQA' }
            '2' { return 'DFeConverterPROD' }
            '3' {
                $custom = Read-Host "Digite o nome exato do servico"
                if (![string]::IsNullOrWhiteSpace($custom)) {
                    return (Normalize-ServiceName $custom)
                } else {
                    Write-Host "Nome invalido. Tente novamente." -ForegroundColor Red
                }
            }
            default { Write-Host "Opcao invalida. Tente novamente." -ForegroundColor Red }
        }
    }
}

function Read-Menu {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                   MENU PRINCIPAL                       ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1) Instalar service"
    Write-Host "  2) Remover service"
    Write-Host "  3) Reinstalar (remove -> install)"
    Write-Host "  4) Status do service"
    Write-Host "  5) Sair"
    Write-Host ""
    $choice = Read-Host "Escolha (1-5)"
    return $choice
}

function Do-Install {
    Write-Host ""
    Write-Host "Baixando dfe-install.ps1..." -ForegroundColor Cyan
    $tempInstall = Download-ScriptToTemp -Name $InstallScriptName
    if (-not $tempInstall) {
        Write-Error "Falha ao baixar $InstallScriptName"
        return
    }
    Invoke-TempPS1 -TempPath $tempInstall
}

function Do-Uninstall {
    Write-Host ""
    Write-Host "Baixando dfe-uninstall. ps1..." -ForegroundColor Cyan
    $tempUninstall = Download-ScriptToTemp -Name $UninstallScriptName
    if (-not $tempUninstall) {
        Write-Error "Falha ao baixar $UninstallScriptName"
        return
    }
    Invoke-TempPS1 -TempPath $tempUninstall
}

function Do-Status {
    $serviceName = Read-ServiceChoice
    if ([string]::IsNullOrWhiteSpace($serviceName)) {
        Write-Host "Nome vazio" -ForegroundColor Red
        return
    }
    try {
        $svc = Get-Service -Name $serviceName -ErrorAction Stop
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║              STATUS DO SERVICO                         ║" -ForegroundColor Cyan
        Write-Host "╚════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Nome          : $($svc.Name)" -ForegroundColor White
        Write-Host "DisplayName   : $($svc. DisplayName)" -ForegroundColor White
        Write-Host "Status        : $($svc.Status)" -ForegroundColor $(if($svc.Status -eq 'Running'){'Green'}else{'Red'})
        Write-Host "StartType     : $($svc.StartType)" -ForegroundColor White
        Write-Host ""
    } catch {
        Write-Warning "Servico '$serviceName' nao encontrado ou erro ao acessar: $($_.Exception. Message)"
    }
}

# ================== Entrypoint ===================
Ensure-Elevated
Show-Banner

Write-Host "Inicializando..." -ForegroundColor Yellow
Write-Host ""

# Tenta baixar bootstrap (opcional, apenas para informar)
$bootstrapPath = Download-ScriptToTemp -Name $BootstrapName
if ($bootstrapPath) {
    Write-Host "Bootstrap baixado: $bootstrapPath" -ForegroundColor Green
    $ok = Run-LinuxBootstrapSafe -BootstrapPath $bootstrapPath
    if (-not $ok) {
        Write-Host "Bootstrap nao executado (esperado em ambiente Windows puro)." -ForegroundColor Yellow
    }
    # Remove bootstrap temp
    if (Test-Path $bootstrapPath) { Remove-Item -Force $bootstrapPath -ErrorAction SilentlyContinue }
} else {
    Write-Host "Bootstrap nao disponivel (normal para setup Windows)." -ForegroundColor Yellow
}

while ($true) {
    $opt = Read-Menu
    switch ($opt) {
        '1' { Do-Install; break }
        '2' { Do-Uninstall; break }
        '3' {
            Write-Host ""
            Write-Host "╔════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
            Write-Host "║                  REINSTALACAO                          ║" -ForegroundColor Magenta
            Write-Host "╚════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
            Write-Host ""
            Write-Host "Passo 1/2: Removendo servico existente..." -ForegroundColor Yellow
            Do-Uninstall
            Write-Host ""
            Write-Host "Passo 2/2: Instalando novamente..." -ForegroundColor Yellow
            Do-Install
            break
        }
        '4' { Do-Status; break }
        '5' {
            Write-Host ""
            Write-Host "Encerrando o setup.  Ate logo!" -ForegroundColor Green
            Write-Host ""
            exit 0
        }
        default { Write-Host "Opcao invalida." -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Read-Host "Pressione ENTER para continuar"
    Show-Banner
}
