<#
dfe-uninstall.ps1 - Desinstalador para services instalados via dfe-install.ps1 (nssm/sc fallback)
Uso: execute em PowerShell Administrador. Opcional: passe -InstallDir para atualizar o .dfe-setup.json naquele local.
#>
param(
    [string]$InstallDir = $PSScriptRoot
)

try { chcp 65001 > $null 2>&1 } catch {}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Log { param([string]$Message) $ts=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); "$ts  $Message" | Tee-Object -FilePath (Join-Path $InstallDir 'nssm-uninstall.log') -Append | Out-Null }

# Elevation check
$currIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = (if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path })
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath)
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        Start-Process -FilePath $pwshCmd.Source -ArgumentList $args -Verb RunAs
    } else {
        $psCmd = Get-Command powershell -ErrorAction SilentlyContinue
        if ($psCmd) { Start-Process -FilePath $psCmd.Source -ArgumentList $args -Verb RunAs }
        else { Write-Error "Nenhum PowerShell encontrado para relancar com privilegios." }
    }
    exit
}

$InstallDir = (Resolve-Path -Path $InstallDir).Path
Log ("InstallDir: {0}" -f $InstallDir)

function Read-ServiceChoice {
    while ($true) {
        Write-Host ""
        Write-Host "Escolha o servico para desinstalar:"
        Write-Host "  1) DFeConverterQA"
        Write-Host "  2) DFeConverterPROD"
        Write-Host "  3) Outro (digite o nome do servico)"
        $choice = Read-Host "Digite a opcao (1/2/3)"
        switch ($choice) {
            '1' { return 'DFeConverterQA' }
            '2' { return 'DFeConverterPROD' }
            '3' {
                $custom = Read-Host "Digite o nome exato do servico (ex.: MeuServico)"
                if (![string]::IsNullOrWhiteSpace($custom)) { return $custom.Trim() } else { Write-Host "Nome invalido. Tente novamente." }
            }
            default { Write-Host "Opcao invalida. Tente novamente." }
        }
    }
}

$ServiceName = Read-ServiceChoice
Log ("Servico selecionado: {0}" -f $ServiceName)

function Ask-YesNoDefaultNo([string]$prompt) {
    while ($true) {
        $r = Read-Host "$prompt (y/N)"
        if ([string]::IsNullOrWhiteSpace($r)) { return $false }
        switch ($r.ToLower()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            default { Write-Host "Resposta invalida. Responda 'y' ou 'n'." }
        }
    }
}

$doRemoveNssm = Ask-YesNoDefaultNo "Remover nssm.exe do directorio da aplicacao?"
Log ("Opcoes escolhidas: RemoveNssm={0}" -f $doRemoveNssm)

$confirm = Ask-YesNoDefaultNo ("Confirmar desinstalacao do servico '{0}' agora?" -f $ServiceName)
if (-not $confirm) {
    Log "Operacao cancelada pelo usuario."
    Write-Host "Operacao cancelada."
    exit 0
}

try {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Log ("Servico encontrado com status: {0}" -f $svc.Status)
        if ($svc.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                Log "Servico parado via Stop-Service."
            } catch {
                Log ("Stop-Service falhou: {0}. Tentando fallback (nssm/sc)..." -f $_.Exception.Message)
                $NssmExe = Join-Path $InstallDir 'nssm.exe'
                if (Test-Path $NssmExe) {
                    & $NssmExe stop $ServiceName 2>&1 | ForEach-Object { Log $_ }
                } else {
                    sc.exe stop $ServiceName | Out-Null
                }
                Start-Sleep -Seconds 2
            }
        } else {
            Log "Servico ja esta parado."
        }
    } else {
        Log ("Servico {0} nao encontrado no sistema." -f $ServiceName)
    }
} catch {
    Log ("Erro ao checar/parar servico: {0}" -f $_.Exception.Message)
}

$removed = $false
$NssmExe = Join-Path $InstallDir 'nssm.exe'
if (Test-Path $NssmExe) {
    try {
        Log ("Tentando remover via nssm: {0} remove {1} confirm" -f $NssmExe, $ServiceName)
        & $NssmExe remove $ServiceName confirm | ForEach-Object { Log $_ }
        $removed = $true
        Log "Comando nssm remove executado."
    } catch {
        Log ("Falha ao remover via nssm: {0}" -f $_.Exception.Message)
    }
}

if (-not $removed) {
    try {
        Log "Tentando remover via sc.exe (fallback)..."
        sc.exe delete $ServiceName | Out-Null
        Log "sc.exe delete executado."
        $removed = $true
    } catch {
        Log ("Falha ao remover via sc.exe: {0}" -f $_.Exception.Message)
    }
}

# Remove Description registry property if present
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (Test-Path $regPath) {
        Log ("Removendo Description em {0}" -f $regPath)
        Remove-ItemProperty -Path $regPath -Name Description -ErrorAction SilentlyContinue
        Log "Description removida (se existia)."
    } else {
        Log ("Chave de registro {0} nao encontrada; nada a remover." -f $regPath)
    }
} catch {
    Log ("Falha ao remover Description do registro: {0}" -f $_.Exception.Message)
}

if ($doRemoveNssm) {
    try {
        if (Test-Path $NssmExe) {
            Log ("Removendo nssm.exe em: {0}" -f $NssmExe)
            Remove-Item -LiteralPath $NssmExe -Force -ErrorAction SilentlyContinue
            Log "nssm.exe removido (se nao estava em uso)."
        } else {
            Log ("nssm.exe nao existe em: {0}" -f $NssmExe)
        }
    } catch {
        Log ("Erro ao remover nssm.exe: {0}" -f $_.Exception.Message)
    }
} else {
    Log "Remocao de nssm.exe ignorada conforme escolha do usuario."
}

# Update JSON in InstallDir: remove only matching serviceName entry
$cfgPath = Join-Path $InstallDir ".dfe-setup.json"
if (Test-Path $cfgPath) {
    try {
        $data = Get-Content $cfgPath -Raw | ConvertFrom-Json
    } catch {
        $data = @{ installations = @() }
    }
    $newList = @()
    foreach ($entry in $data.installations) {
        if ($entry.serviceName -ne $ServiceName) { $newList += $entry }
    }
    if ($newList.Count -gt 0) {
        $out = @{ installations = $newList }
        $out | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding UTF8
        Log "Entrada do servico removida do JSON em $cfgPath"
    } else {
        Remove-Item -Path $cfgPath -Force -ErrorAction SilentlyContinue
        Log "Nenhuma instalacao remanescente; arquivo JSON removido: $cfgPath"
    }
} else {
    Log "Arquivo JSON de estado nao encontrado em: $cfgPath"
}

Log ("Operacao concluida. Verifique Services.msc e o arquivo de log em {0}" -f $InstallDir)
Write-Host "Desinstalacao concluida."
exit 0
