<#
dfe-setup.ps1 - Menu interativo para instalar/remover/reinstalar (Windows)
Execute em PowerShell como Administrador.
#>
[CmdletBinding()]
param()

$SCRIPT_VERSION = "1.0.5"
$RawBase = "https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts"
$BootstrapName = 'dfe-bootstrap.sh'
$InstallScriptName = 'dfe-install.ps1'
$UninstallScriptName = 'dfe-uninstall.ps1'

$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptDir = (Get-Location).Path
} else {
    $ScriptDir = Split-Path -Parent $ScriptPath
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "                                                          " -ForegroundColor Cyan
    Write-Host "           DF-e Converter - Setup (Windows)              " -ForegroundColor Cyan
    Write-Host "                                                          " -ForegroundColor Cyan
    Write-Host "                   Versao: $SCRIPT_VERSION                " -ForegroundColor Cyan
    Write-Host "                                                          " -ForegroundColor Cyan
    Write-Host "              J2R Consultoria Informatica                 " -ForegroundColor Cyan
    Write-Host "                                                          " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Ensure-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Reexecutando em modo Administrador..." -ForegroundColor Yellow
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
        if ($pwsh) { $psi.FileName = $pwsh.Source } else { $psi.FileName = (Get-Command powershell).Source }
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $psi.Verb = "runas"
        try {
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            exit
        } catch {
            Write-Error "Falha ao elevar."
            exit 1
        }
    }
}

function Download-ScriptToTemp {
    param([string]$Name)
    $url = "$RawBase/$Name"
    $dest = Join-Path $env:TEMP $Name
    try {
        Write-Verbose "Baixando $url"
        if (Test-Path $dest) { Remove-Item -Force $dest -ErrorAction SilentlyContinue }
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        return $dest
    } catch {
        Write-Warning "Falha ao baixar $url : $($_.Exception.Message)"
        if (Test-Path $dest) { Remove-Item -Force $dest -ErrorAction SilentlyContinue }
        return $null
    }
}

function Invoke-TempPS1 {
    param([string]$TempPath)
    if (-not (Test-Path $TempPath)) {
        throw "Arquivo PS1 nao encontrado: $TempPath"
    }
    try {
        Write-Host "Executando $TempPath"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $TempPath
    } finally {
        if (Test-Path $TempPath) {
            Remove-Item -Force $TempPath -ErrorAction SilentlyContinue
        }
    }
}

function Normalize-ServiceName {
    param([string]$name)
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }
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
        Write-Host "  3) Outro"
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
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    }
}

function Read-Menu {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "                   MENU PRINCIPAL                         " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1) Instalar service"
    Write-Host "  2) Remover service"
    Write-Host "  3) Reinstalar"
    Write-Host "  4) Status do service"
    Write-Host "  5) Sair"
    Write-Host ""
    $choice = Read-Host "Escolha (1-5)"
    return $choice
}

function Do-Install {
    Write-Host ""
    Write-Host "Baixando instalador..." -ForegroundColor Cyan
    $tempInstall = Download-ScriptToTemp -Name $InstallScriptName
    if (-not $tempInstall) {
        Write-Error "Falha ao baixar instalador"
        return
    }
    Invoke-TempPS1 -TempPath $tempInstall
}

function Do-Uninstall {
    Write-Host ""
    Write-Host "Baixando desinstalador..." -ForegroundColor Cyan
    $tempUninstall = Download-ScriptToTemp -Name $UninstallScriptName
    if (-not $tempUninstall) {
        Write-Error "Falha ao baixar desinstalador"
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
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "              STATUS DO SERVICO                           " -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Nome          : $($svc.Name)"
        Write-Host "DisplayName   : $($svc.DisplayName)"
        $statusColor = if($svc.Status -eq 'Running'){'Green'}else{'Red'}
        Write-Host "Status        : $($svc.Status)" -ForegroundColor $statusColor
        Write-Host "StartType     : $($svc.StartType)"
        Write-Host ""
    } catch {
        Write-Warning "Servico nao encontrado: $serviceName"
    }
}

Ensure-Elevated
Show-Banner

Write-Host "Inicializando..." -ForegroundColor Yellow
Write-Host ""

while ($true) {
    $opt = Read-Menu
    switch ($opt) {
        '1' {
            Do-Install
            break
        }
        '2' {
            Do-Uninstall
            break
        }
        '3' {
            Write-Host ""
            Write-Host "REINSTALACAO" -ForegroundColor Magenta
            Write-Host "Passo 1/2: Removendo..." -ForegroundColor Yellow
            Do-Uninstall
            Write-Host ""
            Write-Host "Passo 2/2: Instalando..." -ForegroundColor Yellow
            Do-Install
            break
        }
        '4' {
            Do-Status
            break
        }
        '5' {
            Write-Host ""
            Write-Host "Encerrando.  Ate logo!" -ForegroundColor Green
            Write-Host ""
            exit 0
        }
        default {
            Write-Host "Opcao invalida." -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "----------------------------------------------------------"
    Read-Host "Pressione ENTER para continuar"
    Show-Banner
}
