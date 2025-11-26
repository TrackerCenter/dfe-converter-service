<#
dfe-setup.ps1 - Menu interativo para instalar / remover /reinstalar (Windows)
Suporta execução inline (iex (New-Object Net.WebClient).DownloadString(...)) ou execução a partir de arquivo.
Se dfe-bootstrap.sh / dfe-install.ps1 / dfe-uninstall.ps1 não existir localmente, serão baixados do raw GitHub
(tenta /main/... e /refs/heads/main/...). Você pode sobrescrever a base raw com DFESCRIPTS_RAW_BASE.
Execute em PowerShell como Administrador.
#>
[CmdletBinding()]
param()

# ---------- Resolve ScriptDir de forma robusta ----------
# Tenta usar PS-provided path variables; se não houver (ex: IE X), usa current location.
$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    # execução inline (iex). Use current location as fallback; marque que estamos inline.
    $ScriptDir = (Get-Location).Path
    $RunningInline = $true
} else {
    $ScriptDir = Split-Path -Parent $ScriptPath
    $RunningInline = $false
}

$BootstrapName = 'dfe-bootstrap.sh'
$InstallScriptName = 'dfe-install.ps1'
$UninstallScriptName = 'dfe-uninstall.ps1'

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

# ---------- Helpers para baixar scripts remotos ----------
function Get-RemoteBaseCandidates {
    # Retorna array de bases raw a tentar (permite override via DFESCRIPTS_RAW_BASE)
    if ($env:DFESCRIPTS_RAW_BASE) {
        return @($env:DFESCRIPTS_RAW_BASE.TrimEnd('/'))
    } else {
        $owner = "TrackerCenter"
        $repo = "dfe-converter-service"
        $branch = "main"
        $base1 = "https://raw.githubusercontent.com/$owner/$repo/$branch/scripts"
        $base2 = "https://raw.githubusercontent.com/$owner/$repo/refs/heads/$branch/scripts"
        return @($base1, $base2)
    }
}

function Download-RemoteScript {
    param(
        [string]$Name
    )
    $bases = Get-RemoteBaseCandidates
    $tmp = Join-Path $env:TEMP ("$Name." + [guid]::NewGuid().ToString())
    foreach ($b in $bases) {
        $url = "$b/$Name"
        try {
            Write-Verbose "Tentando baixar $url"
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            Write-Verbose "Baixado: $tmp"
            return $tmp
        } catch {
            Write-Verbose "Falha ao baixar $url : $($_.Exception.Message)"
            if (Test-Path $tmp) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
        }
    }
    return $null
}

function Get-OrDownload-Script {
    param(
        [string]$Name
    )
    # prioriza arquivo local no mesmo diretório do script
    $localPath = Join-Path $ScriptDir $Name
    if (Test-Path $localPath) {
        Write-Verbose "Usando script local: $localPath"
        return $localPath
    }

    # tenta baixar do raw Github
    $downloaded = Download-RemoteScript -Name $Name
    if ($downloaded) {
        Write-Verbose "Script baixado para $downloaded"
        # se for ps1, garantir extensão .ps1 na temp e retorno do caminho
        return $downloaded
    }

    return $null
}

# ---------- Executores ----------
function Run-LinuxBootstrap {
    param(
        [string]$BootstrapPath
    )
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bashCmd) {
        Write-Warning "Não foi encontrado 'bash' no PATH. O bootstrap é um script POSIX (bash). Para instalar 'jq' em hosts Linux, execute o bootstrap em um host Linux ou instale jq manualmente."
        return $false
    }

    if ($env:AUTO_INSTALL_JQ -eq '1') {
        Write-Host "AUTO_INSTALL_JQ=1 detectado, executando bootstrap sem prompt (--yes)..."
        & $bashCmd.Path $BootstrapPath --yes
    } else {
        Write-Host "Executando bootstrap (pode pedir confirmação para instalar dependências)..."
        & $bashCmd.Path $BootstrapPath
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "O bootstrap retornou código $LASTEXITCODE"
        return $false
    }
    return $true
}

function Invoke-RemoteOrLocal-PS1 {
    param(
        [string]$PathToPS1
    )
    if (-not (Test-Path $PathToPS1)) {
        throw "Script PS1 não encontrado: $PathToPS1"
    }
    Write-Host "Executando: $PathToPS1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $PathToPS1
}

# ---------- Menu / Ações ----------
function Read-Menu {
    Write-Host ""
    Write-Host "=== DFe Converter Setup (Windows) ==="
    Write-Host "1) Instalar service"
    Write-Host "2) Remover service"
    Write-Host "3) Reinstalar (remove -> install)"
    Write-Host "4) Status do service"
    Write-Host "5) Sair"
    $choice = Read-Host "Escolha (1-5)"
    return $choice
}

function Do-Install {
    # tenta usar local ou baixar
    $ps = Get-OrDownload-Script -Name $InstallScriptName
    if (-not $ps) {
        Write-Error "Não foi possível localizar ou baixar $InstallScriptName. Coloque-o em $ScriptDir ou ajuste DFESCRIPTS_RAW_BASE."
        return
    }
    Invoke-RemoteOrLocal-PS1 -PathToPS1 $ps
}

function Do-Uninstall {
    $ps = Get-OrDownload-Script -Name $UninstallScriptName
    if (-not $ps) {
        Write-Error "Não foi possível localizar ou baixar $UninstallScriptName. Coloque-o em $ScriptDir ou ajuste DFESCRIPTS_RAW_BASE."
        return
    }
    Invoke-RemoteOrLocal-PS1 -PathToPS1 $ps
}

function Do-Status {
    $s = Read-Host "Nome do servico para checar"
    if ([string]::IsNullOrWhiteSpace($s)) { Write-Host "Nome vazio"; return }
    Get-Service -Name $s -ErrorAction SilentlyContinue | Format-List *
}

# ================== Entrypoint ===================
Ensure-Elevated

# Tenta obter/baixar bootstrap (local ou remote). Em ambientes IE X sem bash, o bootstrap pode ser ignorado.
$bootstrapPath = $null
$bootstrapLocal = Join-Path $ScriptDir $BootstrapName
if (Test-Path $bootstrapLocal) {
    $bootstrapPath = $bootstrapLocal
} else {
    try {
        $bootstrapPath = Download-RemoteScript -Name $BootstrapName
    } catch {
        $bootstrapPath = $null
    }
}

if ($bootstrapPath) {
    # executa via bash (se disponível)
    $ok = Run-LinuxBootstrap -BootstrapPath $bootstrapPath
    if (-not $ok) {
        Write-Warning "Falha ao executar o bootstrap. Se você estiver em Windows e não precisa do bootstrap local, pode prosseguir com funcionalidades Windows."
    } else {
        Write-Host "Bootstrap executado com sucesso."
    }
} else {
    Write-Host "dfe-bootstrap.sh não encontrado localmente e não foi possível baixar. Se precisar que o setup prepare hosts Linux, coloque dfe-bootstrap.sh em $ScriptDir ou defina DFESCRIPTS_RAW_BASE apontando para o raw correto."
}

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
