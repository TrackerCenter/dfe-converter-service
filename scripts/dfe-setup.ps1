<#
dfe-setup.ps1 - Menu interativo para instalar / remover /reinstalar (Windows)
Coloque dfe-install.ps1 e dfe-uninstall.ps1 no mesmo diretório deste script.
Execute em PowerShell como Administrador.
#>
[CmdletBinding()]
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallScript = Join-Path $ScriptDir 'dfe-install.ps1'
$UninstallScript = Join-Path $ScriptDir 'dfe-uninstall.ps1'

function Ensure-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Reexecutando em modo Administrador..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
        if ($pwsh) { $psi.FileName = $pwsh.Source } else { $psi.FileName = (Get-Command powershell).Source }
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $psi.Verb = "runas"
        try { [System.Diagnostics.Process]::Start($psi) | Out-Null; exit } catch { Write-Error "Falha ao elevar."; exit 1 }
    }
}

function Read-Menu {
    Write-Host ""
    Write-Host "=== DFe Converter Setup (Windows) ==="
    Write-Host "1) Instalar serviço"
    Write-Host "2) Remover serviço"
    Write-Host "3) Reinstalar (remove -> install)"
    Write-Host "4) Status do serviço"
    Write-Host "5) Sair"
    $choice = Read-Host "Escolha (1-5)"
    return $choice
}

function Do-Install {
    if (-not (Test-Path $InstallScript)) { Write-Error "dfe-install.ps1 não encontrado em $ScriptDir"; return }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallScript
}

function Do-Uninstall {
    if (-not (Test-Path $UninstallScript)) { Write-Error "dfe-uninstall.ps1 não encontrado em $ScriptDir"; return }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $UninstallScript
}

function Do-Status {
    $s = Read-Host "Nome do servico para checar"
    if ([string]::IsNullOrWhiteSpace($s)) { Write-Host "Nome vazio"; return }
    Get-Service -Name $s -ErrorAction SilentlyContinue | Format-List *
}

Ensure-Elevated

while ($true) {
    $opt = Read-Menu
    switch ($opt) {
        '1' { Do-Install; break }
        '2' { Do-Uninstall; break }
        '3' { Do-Uninstall; Do-Install; break }
        '4' { Do-Status; break }
        '5' { Write-Host "Saindo."; exit 0 }
        default { Write-Host "Opcao invalida." }
    }
}