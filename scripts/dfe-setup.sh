<#
dfe-setup.ps1 - Menu interativo para instalar / remover /reinstalar (Windows)
Coloque dfe-install.ps1 e dfe-uninstall.ps1 no mesmo diretório deste script.
Se dfe-bootstrap.sh não existir localmente, este script tentará baixá-lo
do raw GitHub (tenta padrões /main/... e /refs/heads/main/...) ou usar
DFESCRIPTS_RAW_BASE quando definido. Em seguida executa o bootstrap via bash
para garantir dependências (jq) antes de prosseguir no Linux.
Execute em PowerShell como Administrador.
#>
[CmdletBinding()]
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallScript = Join-Path $ScriptDir 'dfe-install.ps1'
$UninstallScript = Join-Path $ScriptDir 'dfe-uninstall.ps1'
$BootstrapName = 'dfe-bootstrap.sh'

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

function Get-BootstrapPath {
    param(
        [string]$ScriptDir,
        [string]$BootstrapName = 'dfe-bootstrap.sh'
    )

    $local = Join-Path $ScriptDir $BootstrapName
    if (Test-Path $local) {
        Write-Verbose "Bootstrap local encontrado: $local"
        return $local
    }

    # Build candidate bases
    if ($env:DFESCRIPTS_RAW_BASE) {
        $bases = @($env:DFESCRIPTS_RAW_BASE.TrimEnd('/'))
    } else {
        $owner = "TrackerCenter"
        $repo = "dfe-converter-service"
        $branch = "main"
        $base1 = "https://raw.githubusercontent.com/$owner/$repo/$branch/scripts"
        $base2 = "https://raw.githubusercontent.com/$owner/$repo/refs/heads/$branch/scripts"
        $bases = @($base1, $base2)
    }

    # create temp filename
    $tmp = Join-Path $env:TEMP ("$BootstrapName." + [guid]::NewGuid().ToString() + ".sh")

    foreach ($b in $bases) {
        $url = "$b/$BootstrapName"
        Write-Verbose "Tentando baixar bootstrap de: $url"
        try {
            # prefer Invoke-WebRequest; em PS7 UseBasicParsing não é necessário
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            # ensure executable permission if bash on Windows (WSL / Git Bash), not necessary but keep file
            return $tmp
        } catch {
            Write-Verbose "Falha ao baixar $url : $($_.Exception.Message)"
            if (Test-Path $tmp) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
        }
    }

    throw "Falha ao baixar $BootstrapName; tente definir DFESCRIPTS_RAW_BASE para apontar para a pasta raw correta, ou coloque $BootstrapName em $ScriptDir"
}

function Run-LinuxBootstrap {
    param(
        [string]$BootstrapPath
    )
    # verifica se existe bash disponível (Git Bash, WSL, Cygwin ou bash no PATH)
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bashCmd) {
        Write-Warning "Não foi encontrado 'bash' no PATH. O bootstrap é um script POSIX (bash). Instale bash (ex: Git Bash / WSL) ou coloque dfe-bootstrap.sh localmente no host Linux que executará o setup."
        return $false
    }

    # se AUTO_INSTALL_JQ=1 estiver definido no ambiente Windows, repassamos via variável de ambiente
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

# ================== Entrypoint ===================
Ensure-Elevated

# Tenta obter bootstrap (local ou baixar dos raw URLs)
$bootstrapPath = $null
try {
    $bootstrapPath = Get-BootstrapPath -ScriptDir $ScriptDir -BootstrapName $BootstrapName
} catch {
    Write-Warning $_.Exception.Message
    # Se não houve bootstrap, prosseguimos apenas com o menu Windows (não temos dependência de jq no Windows)
    Write-Host "Continuando sem executar dfe-bootstrap.sh (apenas funcionalidade Windows estará disponível)."
    $bootstrapPath = $null
}

if ($bootstrapPath) {
    # Executa bootstrap via bash (apenas necessário para máquinas Linux; em Windows permite preparar hosts Linux remotos)
    $ok = Run-LinuxBootstrap -BootstrapPath $bootstrapPath
    if (-not $ok) {
        Write-Warning "Falha ao executar o bootstrap. Se você estiver em ambiente Windows e não usar o bootstrap, pode ignorar."
    } else {
        Write-Host "Bootstrap executado com sucesso."
    }
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
