<#
dfe-setup.ps1 - Menu interativo para instalar/remover/reinstalar (Windows)
Versao: 1.2.0
Execute em PowerShell como Administrador.
#>
[CmdletBinding()]
param()

$SCRIPT_VERSION = "1.2.0"
$RawBase = "https://raw.githubusercontent.com/TrackerCenter/dfe-converter-service/refs/heads/main/scripts"
$BootstrapName = 'dfe-bootstrap.sh'
$InstallScriptName = 'dfe-install.ps1'
$UninstallScriptName = 'dfe-uninstall.ps1'
$UpdateScriptName = 'dfe-update.ps1'

$DFE_AUTOUPDATE_SCRIPT = "C:\ProgramData\dfe-autoupdate.ps1"
$DFE_AUTOUPDATE_TASK_PREFIX = "DFe-AutoUpdate"

# Session-scoped state set by Ensure-ApiUrl
$script:TrackerApiUrl = if ($env:TRACKER_API_URL) { $env:TRACKER_API_URL } else { "" }
$script:DfeAmbiente   = if ($env:DFE_AMBIENTE)   { $env:DFE_AMBIENTE }   else { "" }

$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptDir = (Get-Location).Path
} else {
    $ScriptDir = Split-Path -Parent $ScriptPath
}

# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------

function Read-EnvValue {
    param([string]$Key, [string]$File)
    if (-not (Test-Path $File)) { return "" }
    $line = Get-Content $File -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^${Key}=", "").Trim() }
    return ""
}

# Returns list of directories that have a valid .dfe-setup.env
function Find-DfeInstallations {
    $found = [System.Collections.Generic.List[string]]::new()
    $seen  = @{}

    foreach ($dir in @("C:\DFE_CONVERTER_QA", "C:\DFE_CONVERTER_PROD")) {
        $envFile = Join-Path $dir ".dfe-setup.env"
        if ((Test-Path $envFile) -and -not $seen.ContainsKey($dir)) {
            $found.Add($dir)
            $seen[$dir] = 1
        }
    }

    # Also discover via running DFe* services using WMI PathName
    $dfeServices = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^DFe' }
    foreach ($svc in $dfeServices) {
        try {
            $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
            if ($wmiSvc -and $wmiSvc.PathName) {
                # PathName may be: "C:\path\nssm.exe" or similar — extract dir
                $raw = $wmiSvc.PathName.Trim('"')
                # nssm wraps: C:\...\nssm.exe; the appdir is set separately via nssm AppDirectory
                # Best-effort: take the first quoted or unquoted path segment
                if ($raw -match '^"?([^"]+)"?') { $raw = $Matches[1] }
                $dir = Split-Path -Parent $raw
                $envFile = Join-Path $dir ".dfe-setup.env"
                if ((Test-Path $envFile) -and -not $seen.ContainsKey($dir)) {
                    $found.Add($dir)
                    $seen[$dir] = 1
                }
            }
        } catch {}
    }
    return $found.ToArray()
}

# Prompts user to pick one of the discovered installations.
# Returns dir string or $null if cancelled.
function Select-InstallDir {
    $installations = Find-DfeInstallations

    if ($installations.Count -eq 0) {
        Write-Host ""
        Write-Host "  Nenhuma instalacao encontrada nos locais padrao." -ForegroundColor Yellow
        Write-Host "  Use a opcao 1 (Instalar service) para instalar o DFe Converter." -ForegroundColor Yellow
        $custom = Read-Host "Informe o diretorio com instalacao existente (vazio para cancelar)"
        if ([string]::IsNullOrWhiteSpace($custom)) { return $null }
        $custom = $custom.TrimEnd('\').Trim()
        if (-not (Test-Path (Join-Path $custom ".dfe-setup.env"))) {
            Write-Host "  AVISO: '$custom' nao possui instalacao DFe (.dfe-setup.env nao encontrado)." -ForegroundColor Yellow
            return $null
        }
        return $custom
    }

    if ($installations.Count -eq 1) {
        Write-Host "  Instalacao encontrada: $($installations[0])" -ForegroundColor Cyan
        return $installations[0]
    }

    Write-Host ""
    Write-Host "  Instalacoes encontradas:"
    $i = 1
    foreach ($dir in $installations) {
        $envFile = Join-Path $dir ".dfe-setup.env"
        $svc = Read-EnvValue "DFE_SERVICE_NAME" $envFile
        $ver = Read-EnvValue "DFE_VERSAO" $envFile
        Write-Host ("  {0}) {1,-40}  service={2,-25}  versao={3}" -f `
            $i, $dir, $(if ($svc) { $svc } else { "?" }), $(if ($ver) { $ver } else { "?" }))
        $i++
    }
    Write-Host ""
    $choice = Read-Host "Escolha a instalacao (1-$($installations.Count))"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $installations.Count) {
        Write-Host "  Opcao invalida." -ForegroundColor Red
        return $null
    }
    return $installations[$idx]
}

# ---------------------------------------------------------------------------
# Ensure-ApiUrl — interactive server + ambiente selection
# ---------------------------------------------------------------------------

function Ensure-ApiUrl {
    if (-not [string]::IsNullOrWhiteSpace($script:TrackerApiUrl)) { return }

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "         SELECIONAR SERVIDOR DO TRACKER" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Define de onde baixar os scripts e executaveis."
    Write-Host "  Ambos os servidores contem executaveis de QA e PROD."
    Write-Host ""
    Write-Host "  1) QA   - https://qa.trackercenter.com.br/app (mais recente)"
    Write-Host "  2) PROD - https://prod.trackercenter.com.br/app (estavel)"
    Write-Host "  3) URL personalizada"
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Escolha (1-3)"
        switch ($choice) {
            '1' {
                $script:TrackerApiUrl = "https://qa.trackercenter.com.br/app"
                $script:DfeAmbiente   = "QA"
                Write-Host ""
                Write-Host "  Servidor: $($script:TrackerApiUrl)" -ForegroundColor Cyan
                return
            }
            '2' {
                $script:TrackerApiUrl = "https://prod.trackercenter.com.br/app"
                $script:DfeAmbiente   = "PROD"
                Write-Host ""
                Write-Host "  Servidor: $($script:TrackerApiUrl)" -ForegroundColor Cyan
                return
            }
            '3' {
                $customUrl = Read-Host "URL base do Tracker (ex: https://tracker.seudominio.com/app)"
                if ([string]::IsNullOrWhiteSpace($customUrl)) {
                    Write-Host "  URL invalida. Tente novamente." -ForegroundColor Red
                    continue
                }
                $script:TrackerApiUrl = $customUrl.TrimEnd('/')
                # Ask ambiente separately for custom URL
                while ($true) {
                    Write-Host "  Ambiente do executavel:"
                    Write-Host "    1) QA"
                    Write-Host "    2) PROD"
                    $envChoice = Read-Host "  Escolha (1-2)"
                    switch ($envChoice) {
                        '1' { $script:DfeAmbiente = "QA";   break }
                        '2' { $script:DfeAmbiente = "PROD"; break }
                        default { Write-Host "  Opcao invalida. Escolha 1 ou 2." -ForegroundColor Red; continue }
                    }
                    break
                }
                Write-Host ""
                Write-Host "  Servidor: $($script:TrackerApiUrl)  Ambiente: $($script:DfeAmbiente)" -ForegroundColor Cyan
                return
            }
            default { Write-Host "  Opcao invalida. Escolha 1, 2 ou 3." -ForegroundColor Red }
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: parse KEY=VALUE response from API info endpoint
# ---------------------------------------------------------------------------
function Parse-InfoValue {
    param([string]$Key, [string]$Text)
    $line = $Text -split "`n" | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^${Key}=", "").Trim() }
    return ""
}

# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------

function Do-Install {
    Ensure-ApiUrl

    # Fetch version info from API
    $infoUrl = "$($script:TrackerApiUrl)/api/v1/dfe-converter/versoes/latest/info?ambiente=$($script:DfeAmbiente)&tipo=EXE"
    Write-Host ""
    Write-Host "  Consultando versao disponivel ($($script:DfeAmbiente))..." -ForegroundColor Cyan
    $remoteVersao = ""; $remoteNome = ""; $remoteTamanho = ""; $remoteData = ""
    try {
        $infoText = (Invoke-WebRequest -Uri $infoUrl -UseBasicParsing -ErrorAction Stop).Content
        $remoteVersao   = Parse-InfoValue "DFE_VERSAO"        $infoText
        $remoteNome     = Parse-InfoValue "DFE_NOME_ARQUIVO"  $infoText
        $remoteTamanho  = Parse-InfoValue "DFE_TAMANHO_BYTES" $infoText
        $remoteData     = Parse-InfoValue "DFE_DATA_UPLOAD"   $infoText
    } catch {
        Write-Host "  AVISO: nao foi possivel consultar versao: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    if (-not $remoteNome) { $remoteNome = "DFe-Converter-$($script:DfeAmbiente).exe" }
    $tamMB = if ($remoteTamanho) { [math]::Round([long]$remoteTamanho / 1MB, 1) } else { "?" }

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "         VERSAO DISPONIVEL PARA INSTALACAO" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  Ambiente : {0}" -f $script:DfeAmbiente)
    Write-Host ("  Versao   : {0}" -f $(if ($remoteVersao) { $remoteVersao } else { "?" }))
    Write-Host ("  Arquivo  : {0}" -f $remoteNome)
    Write-Host ("  Tamanho  : {0} MB" -f $tamMB)
    Write-Host ("  Data     : {0}" -f $(if ($remoteData) { $remoteData } else { "?" }))
    Write-Host ""

    # Default install dir based on ambiente
    $defaultDir = if ($script:DfeAmbiente -eq "PROD") { "C:\DFE_CONVERTER_PROD" } else { "C:\DFE_CONVERTER_QA" }
    $installDir = Read-Host "  Diretorio de instalacao [$defaultDir]"
    if ([string]::IsNullOrWhiteSpace($installDir)) { $installDir = $defaultDir }
    $installDir = $installDir.Trim()

    # Check if version already installed
    $stateFile = Join-Path $installDir ".dfe-setup.env"
    if ((Test-Path $stateFile) -and -not [string]::IsNullOrWhiteSpace($remoteVersao)) {
        $installedVersao = Read-EnvValue "DFE_VERSAO" $stateFile
        if (-not [string]::IsNullOrWhiteSpace($installedVersao) -and $installedVersao -eq $remoteVersao) {
            Write-Host "  Versao instalada ($installedVersao) ja e a mais recente." -ForegroundColor Yellow
            $forceReinst = Read-Host "  Forcar reinstalacao? [y/N]"
            if ($forceReinst -notmatch '^[yYsS]') {
                Write-Host "  Operacao cancelada." -ForegroundColor Yellow
                return
            }
        }
    }

    $yn = Read-Host "Prosseguir com a instalacao? [y/N]"
    if ($yn -notmatch '^[yYsS]') {
        Write-Host "  Instalacao cancelada." -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $installDir)) {
        try {
            New-Item -Path $installDir -ItemType Directory -Force | Out-Null
            Write-Host "  Diretorio criado: $installDir" -ForegroundColor Green
        } catch {
            Write-Warning "  Falha ao criar diretorio: $($_.Exception.Message)"
            return
        }
    }

    # Download EXE to install dir before calling installer
    $downloadUrl  = "$($script:TrackerApiUrl)/api/v1/dfe-converter/versoes/latest/download?ambiente=$($script:DfeAmbiente)&tipo=EXE"
    $exeDestPath  = Join-Path $installDir $remoteNome
    Write-Host ""
    Write-Host "  Baixando $remoteNome..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $exeDestPath -UseBasicParsing -ErrorAction Stop
        Write-Host "  Download concluido: $exeDestPath" -ForegroundColor Green
    } catch {
        Write-Host "  ERRO ao baixar o executavel: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    # Derive service/display name defaults from ambiente
    $defaultSvcName  = if ($script:DfeAmbiente -eq "PROD") { "DFeConverterPROD" } else { "DFeConverterQA" }
    $defaultDispName = if ($script:DfeAmbiente -eq "PROD") { "DF-e Converter PROD" } else { "DF-e Converter QA" }

    Write-Host ""
    Write-Host "  Configurando service..." -ForegroundColor Cyan
    $localInstall = Join-Path $ScriptDir $InstallScriptName
    if (Test-Path $localInstall) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $localInstall `
            -InstallDir $installDir -JarName $remoteNome -Ambiente $script:DfeAmbiente `
            -ServiceName $defaultSvcName -DisplayName $defaultDispName -Versao $remoteVersao
    } else {
        $tempInstall = Download-ScriptToTemp -Name $InstallScriptName
        if (-not $tempInstall) { Write-Error "Falha ao baixar instalador"; return }
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $tempInstall `
                -InstallDir $installDir -JarName $remoteNome -Ambiente $script:DfeAmbiente `
                -ServiceName $defaultSvcName -DisplayName $defaultDispName -Versao $remoteVersao
        } finally {
            if (Test-Path $tempInstall) { Remove-Item -Force $tempInstall -ErrorAction SilentlyContinue }
        }
    }
}

function Do-Uninstall {
    Write-Host ""
    Write-Host "Baixando desinstalador..." -ForegroundColor Cyan
    $localUninstall = Join-Path $ScriptDir $UninstallScriptName
    if (Test-Path $localUninstall) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $localUninstall
    } else {
        $tempUninstall = Download-ScriptToTemp -Name $UninstallScriptName
        if (-not $tempUninstall) { Write-Error "Falha ao baixar desinstalador"; return }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tempUninstall
        if (Test-Path $tempUninstall) { Remove-Item -Force $tempUninstall -ErrorAction SilentlyContinue }
    }
}

function Do-ReinstallService {
    $installDir = Select-InstallDir
    if ($null -eq $installDir) { return }

    $stateFile = Join-Path $installDir ".dfe-setup.env"
    if (-not (Test-Path $stateFile)) {
        Write-Host "  ERRO: state file nao encontrado em $installDir" -ForegroundColor Red
        return
    }

    $svcName  = Read-EnvValue "DFE_SERVICE_NAME" $stateFile
    $jarName  = Read-EnvValue "DFE_JAR_NAME"     $stateFile
    $cfgName  = Read-EnvValue "DFE_CONFIG_NAME"  $stateFile
    $versao   = Read-EnvValue "DFE_VERSAO"       $stateFile
    $ambiente = Read-EnvValue "DFE_AMBIENTE"     $stateFile

    $jarPath = Join-Path $installDir $(if ($jarName) { $jarName } else { "DFe-Converter.exe" })
    $cfgPath = Join-Path $installDir $(if ($cfgName) { $cfgName } else { "config.properties" })

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Magenta
    Write-Host "      REINSTALAR SERVICE (sem alterar EXE/config)" -ForegroundColor Magenta
    Write-Host "==========================================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host ("  Servico      : {0}" -f $(if ($svcName)  { $svcName }  else { "?" }))
    Write-Host ("  Instalado em : {0}" -f $installDir)
    Write-Host ("  Versao       : {0}" -f $(if ($versao)   { $versao }   else { "?" }))
    Write-Host ("  Ambiente     : {0}" -f $(if ($ambiente) { $ambiente } else { "?" }))
    Write-Host ("  EXE          : {0}" -f $jarPath)
    Write-Host ("  Config       : {0}" -f $cfgPath)
    Write-Host ""

    $erros = 0
    if (-not (Test-Path $jarPath)) {
        Write-Host "  ERRO: EXE nao encontrado: $jarPath" -ForegroundColor Red; $erros++
    }
    if (-not (Test-Path $cfgPath)) {
        Write-Host "  ERRO: config nao encontrado: $cfgPath" -ForegroundColor Red; $erros++
    }
    if ($erros -gt 0) { return }

    $yn = Read-Host "  Reinstalar a service Windows do servico? [y/N]"
    if ($yn -notmatch '^[yYsS]') {
        Write-Host "  Operacao cancelada." -ForegroundColor Yellow
        return
    }

    # Stop existing service if running
    if (-not [string]::IsNullOrWhiteSpace($svcName)) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') {
            Write-Host "  Parando servico '$svcName'..." -ForegroundColor Yellow
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    Write-Host ""
    Write-Host "  Baixando instalador..." -ForegroundColor Cyan
    $localInstall = Join-Path $ScriptDir $InstallScriptName
    if (Test-Path $localInstall) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $localInstall -InstallDir $installDir
    } else {
        $tempInstall = Download-ScriptToTemp -Name $InstallScriptName
        if (-not $tempInstall) { Write-Error "Falha ao baixar instalador"; return }
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $tempInstall -InstallDir $installDir
        } finally {
            if (Test-Path $tempInstall) { Remove-Item -Force $tempInstall -ErrorAction SilentlyContinue }
        }
    }

    # Show service status after reinstall
    if (-not [string]::IsNullOrWhiteSpace($svcName)) {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host ""
            Write-Host "  Status apos reinstalacao:" -ForegroundColor Cyan
            $statusColor = if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' }
            Write-Host ("  {0}: {1}" -f $svc.Name, $svc.Status) -ForegroundColor $statusColor
        }
    }
}

function Do-ListServices {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "           SERVICOS DFe INSTALADOS" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""

    # Collect service info: name -> @{Service; InstallDir}
    $serviceMap = [ordered]@{}

    # Discover via Get-Service matching DFe*
    $svcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^DFe' }
    foreach ($svc in $svcs) {
        if (-not $serviceMap.Contains($svc.Name)) {
            $serviceMap[$svc.Name] = @{ Service = $svc; InstallDir = "" }
        }
    }

    # Discover via state files — link service name to install dir
    foreach ($dir in (Find-DfeInstallations)) {
        $envFile = Join-Path $dir ".dfe-setup.env"
        $svcName = Read-EnvValue "DFE_SERVICE_NAME" $envFile
        if (-not [string]::IsNullOrWhiteSpace($svcName)) {
            if (-not $serviceMap.Contains($svcName)) {
                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                $serviceMap[$svcName] = @{ Service = $svc; InstallDir = $dir }
            } else {
                $serviceMap[$svcName].InstallDir = $dir
            }
        }
    }

    if ($serviceMap.Count -eq 0) {
        Write-Host "  Nenhum servico DFe encontrado."
        Write-Host ""
        return
    }

    Write-Host ("  {0,-32}  {1,-18}  {2,-10}  {3}" -f "SERVICO", "ESTADO", "VERSAO", "INSTALADO EM")
    Write-Host ("  {0}" -f ("-" * 80))

    foreach ($kvp in $serviceMap.GetEnumerator()) {
        $svcName   = $kvp.Key
        $info      = $kvp.Value
        $svc       = $info.Service
        $installDir = $info.InstallDir

        $estadoTxt = if ($svc) {
            switch ($svc.Status) {
                'Running'      { "[OK] Rodando" }
                'Stopped'      { "[--] Parado" }
                'StartPending' { "[..] Iniciando" }
                'StopPending'  { "[..] Parando" }
                'Failed'       { "[!!] Falhou" }
                default        { "[??] $($svc.Status)" }
            }
        } else { "[!!] Nao encontrado" }

        $versao = "-"
        if (-not [string]::IsNullOrWhiteSpace($installDir)) {
            $envFile = Join-Path $installDir ".dfe-setup.env"
            if (Test-Path $envFile) {
                $v = Read-EnvValue "DFE_VERSAO" $envFile
                if ($v) { $versao = "v$v" }
            }
        }

        $installDirDisplay = if ($installDir) { $installDir } else { "-" }
        Write-Host ("  {0,-32}  {1,-18}  {2,-10}  {3}" -f $svcName, $estadoTxt, $versao, $installDirDisplay)
    }
    Write-Host ""
}

function Do-Status {
    # Collect service names from state files first
    $serviceNames = [System.Collections.Generic.List[string]]::new()

    foreach ($dir in (Find-DfeInstallations)) {
        $envFile = Join-Path $dir ".dfe-setup.env"
        $svcName = Read-EnvValue "DFE_SERVICE_NAME" $envFile
        if (-not [string]::IsNullOrWhiteSpace($svcName) -and -not $serviceNames.Contains($svcName)) {
            $serviceNames.Add($svcName)
        }
    }

    # Fallback: Get-Service matching DFe*
    if ($serviceNames.Count -eq 0) {
        $svcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^DFe' }
        foreach ($svc in $svcs) {
            if (-not $serviceNames.Contains($svc.Name)) { $serviceNames.Add($svc.Name) }
        }
    }

    if ($serviceNames.Count -eq 0) {
        Write-Host ""
        Write-Host "  Nenhum servico DFe encontrado." -ForegroundColor Yellow
        Write-Host "  Use a opcao 1 (Instalar service) para instalar o DFe Converter."
        Write-Host ""
        return
    }

    # Select service if multiple
    $serviceName = ""
    if ($serviceNames.Count -eq 1) {
        $serviceName = $serviceNames[0]
    } else {
        Write-Host ""
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "              SELECIONAR SERVICO" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host ""
        $i = 1
        foreach ($sn in $serviceNames) {
            $svc   = Get-Service -Name $sn -ErrorAction SilentlyContinue
            $state = if ($svc) { $svc.Status.ToString() } else { "nao encontrado" }
            Write-Host ("  {0}) {1,-35} [{2}]" -f $i, $sn, $state)
            $i++
        }
        Write-Host ""
        $choice = Read-Host "Escolha o servico (1-$($serviceNames.Count))"
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $serviceNames.Count) {
            Write-Host "  Opcao invalida." -ForegroundColor Red
            return
        }
        $serviceName = $serviceNames[$idx]
    }

    # Submenu — stays until user chooses Voltar
    while ($true) {
        $svc   = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $state = if ($svc) { $svc.Status.ToString() } else { "nao encontrado" }

        Write-Host ""
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host ("   SERVICO: {0,-30} [{1}]" -f $serviceName, $state) -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  1) Ver detalhes"
        Write-Host "  2) Reiniciar"
        Write-Host "  3) Iniciar"
        Write-Host "  4) Parar"
        Write-Host "  5) Voltar"
        Write-Host ""

        $action = Read-Host "Escolha (1-5)"
        switch ($action) {
            '1' {
                Write-Host ""
                Write-Host "==========================================================" -ForegroundColor Cyan
                Write-Host "              STATUS DO SERVICO" -ForegroundColor Cyan
                Write-Host "==========================================================" -ForegroundColor Cyan
                Write-Host ""
                if ($svc) {
                    Write-Host "Nome          : $($svc.Name)"
                    Write-Host "DisplayName   : $($svc.DisplayName)"
                    $statusColor = if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' }
                    Write-Host "Status        : $($svc.Status)" -ForegroundColor $statusColor
                    Write-Host "StartType     : $($svc.StartType)"
                } else {
                    Write-Host "  Servico nao encontrado: $serviceName" -ForegroundColor Red
                }
                Write-Host ""
                Read-Host "Pressione ENTER para continuar"
            }
            '2' {
                Write-Host ""
                Write-Host "  Reiniciando '$serviceName'..." -ForegroundColor Yellow
                try {
                    Restart-Service -Name $serviceName -Force -ErrorAction Stop
                    Write-Host "  Servico reiniciado com sucesso." -ForegroundColor Green
                } catch {
                    Write-Host "  Falha ao reiniciar: $($_.Exception.Message)" -ForegroundColor Red
                }
                Write-Host ""
                Read-Host "Pressione ENTER para continuar"
            }
            '3' {
                Write-Host ""
                Write-Host "  Iniciando '$serviceName'..." -ForegroundColor Yellow
                try {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Write-Host "  Servico iniciado com sucesso." -ForegroundColor Green
                } catch {
                    Write-Host "  Falha ao iniciar: $($_.Exception.Message)" -ForegroundColor Red
                }
                Write-Host ""
                Read-Host "Pressione ENTER para continuar"
            }
            '4' {
                Write-Host ""
                Write-Host "  Parando '$serviceName'..." -ForegroundColor Yellow
                try {
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    Write-Host "  Servico parado." -ForegroundColor Green
                } catch {
                    Write-Host "  Falha ao parar: $($_.Exception.Message)" -ForegroundColor Red
                }
                Write-Host ""
                Read-Host "Pressione ENTER para continuar"
            }
            '5' { return }
            default { Write-Host "  Opcao invalida. Escolha 1, 2, 3, 4 ou 5." -ForegroundColor Red }
        }
    }
}

function Do-CheckUpdate {
    Ensure-ApiUrl
    $localPath = Join-Path $ScriptDir $UpdateScriptName
    if (Test-Path $localPath) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $localPath -ApiUrl $script:TrackerApiUrl -Ambiente $script:DfeAmbiente
    } else {
        $tempUpdate = Download-ScriptToTemp -Name $UpdateScriptName
        if (-not $tempUpdate) { Write-Error "Falha ao baixar $UpdateScriptName"; return }
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $tempUpdate -ApiUrl $script:TrackerApiUrl -Ambiente $script:DfeAmbiente
        } finally {
            if (Test-Path $tempUpdate) { Remove-Item -Force $tempUpdate -ErrorAction SilentlyContinue }
        }
    }
}

function Do-Update {
    Ensure-ApiUrl
    $localPath = Join-Path $ScriptDir $UpdateScriptName
    if (Test-Path $localPath) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $localPath -ApiUrl $script:TrackerApiUrl -Ambiente $script:DfeAmbiente -Yes
    } else {
        $tempUpdate = Download-ScriptToTemp -Name $UpdateScriptName
        if (-not $tempUpdate) { Write-Error "Falha ao baixar $UpdateScriptName"; return }
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $tempUpdate -ApiUrl $script:TrackerApiUrl -Ambiente $script:DfeAmbiente -Yes
        } finally {
            if (Test-Path $tempUpdate) { Remove-Item -Force $tempUpdate -ErrorAction SilentlyContinue }
        }
    }
}

# ---------------------------------------------------------------------------
# Auto-update via Windows Task Scheduler
# ---------------------------------------------------------------------------

function Show-AutoUpdateStatus {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "           STATUS DO AUTO-UPDATE" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""

    $tasks = Get-ScheduledTask -TaskName "${DFE_AUTOUPDATE_TASK_PREFIX}*" -ErrorAction SilentlyContinue
    if ($tasks) {
        foreach ($task in $tasks) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction SilentlyContinue
            Write-Host "  Status      : [ATIVO]" -ForegroundColor Green
            Write-Host "  Tarefa      : $($task.TaskName)"
            if ($taskInfo) {
                Write-Host "  Ultima exec : $($taskInfo.LastRunTime)"
                Write-Host "  Proxima exec: $($taskInfo.NextRunTime)"
            }
        }
    } else {
        Write-Host "  Status      : [INATIVO]" -ForegroundColor Yellow
    }

    if (Test-Path $DFE_AUTOUPDATE_SCRIPT) {
        $scriptLines = Get-Content $DFE_AUTOUPDATE_SCRIPT -ErrorAction SilentlyContinue
        $configUrl = ($scriptLines | Where-Object { $_ -match '^\$TrackerApiUrl\s*=' } | Select-Object -First 1) -replace '.*=\s*"([^"]*)".*', '$1'
        $configEnv = ($scriptLines | Where-Object { $_ -match '^\$DfeAmbiente\s*=' }   | Select-Object -First 1) -replace '.*=\s*"([^"]*)".*', '$1'
        $configDir = ($scriptLines | Where-Object { $_ -match '^\$InstallDir\s*=' }    | Select-Object -First 1) -replace '.*=\s*"([^"]*)".*', '$1'
        Write-Host "  Script      : $DFE_AUTOUPDATE_SCRIPT"
        if ($configUrl) { Write-Host "  URL         : $configUrl" }
        if ($configEnv) { Write-Host "  Ambiente    : $configEnv" }
        if ($configDir) {
            Write-Host "  Install dir : $configDir"
            $sf = Join-Path $configDir ".dfe-setup.env"
            if (Test-Path $sf) {
                Write-Host "  State file  : OK ($sf)"
            } else {
                Write-Host "  State file  : AVISO - nao encontrado ($sf)" -ForegroundColor Yellow
            }
        }
        # Find log from configured dir or fallback
        $logFile = if ($configDir) { Join-Path $configDir "dfe-autoupdate.log" } else { "C:\DFE_CONVERTER_QA\dfe-autoupdate.log" }
        Write-Host "  Log         : $logFile"
        if (Test-Path $logFile) {
            Write-Host ""
            Write-Host "  --- Ultimas entradas do log ---"
            Get-Content $logFile -Tail 5 | ForEach-Object { Write-Host "  $_" }
            Write-Host "  ---"
        } else {
            Write-Host ""
            Write-Host "  Log ainda nao existe. Sera criado na proxima execucao."
        }
    } else {
        Write-Host "  Script      : nao encontrado ($DFE_AUTOUPDATE_SCRIPT)"
    }
    Write-Host ""
}

function Write-AutoUpdateScript {
    param([string]$InstallDir)

    $genDate      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $apiUrl       = $script:TrackerApiUrl
    $ambiente     = $script:DfeAmbiente
    $updateUrl    = "$RawBase/$UpdateScriptName"
    $logFile      = Join-Path $InstallDir "dfe-autoupdate.log"

    # Build script lines; backtick-$ for variables that must be literal in generated script
    $lines = @(
        "# Gerado automaticamente pelo dfe-setup.ps1 em $genDate",
        "# Ambiente: $ambiente | URL: $apiUrl",
        "# Para reconfigurar execute dfe-setup.ps1 (opcao 8)",
        "",
        "`$TrackerApiUrl  = `"$apiUrl`"",
        "`$DfeAmbiente    = `"$ambiente`"",
        "`$InstallDir     = `"$InstallDir`"",
        "`$StateFile      = Join-Path `$InstallDir `".dfe-setup.env`"",
        "`$LogFile        = `"$logFile`"",
        "`$ReportApiUrl   = `"`$TrackerApiUrl/api/v1/dfeConverterRelatorio`"",
        "`$UpdateScriptUrl = `"$updateUrl`"",
        "",
        'function Log-Au { param($m)',
        '    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")',
        '    "$ts dfe-autoupdate $m" | Tee-Object -FilePath $LogFile -Append | Out-Null',
        '}',
        "",
        'function Read-State { param($k)',
        '    if (-not (Test-Path $StateFile)) { return "" }',
        '    $line = Get-Content $StateFile -ErrorAction SilentlyContinue | Where-Object { $_ -match "^${k}=" } | Select-Object -First 1',
        '    if ($line) { return ($line -replace "^${k}=","").Trim() }',
        '    return ""',
        '}',
        "",
        'function Write-StateVal { param($k,$v)',
        '    if (-not (Test-Path $StateFile)) { New-Item -ItemType File -Path $StateFile -Force | Out-Null }',
        '    $c = @(Get-Content $StateFile -ErrorAction SilentlyContinue)',
        '    $found = $false',
        '    $c = $c | ForEach-Object { if ($_ -match "^${k}=") { "${k}=${v}"; $found = $true } else { $_ } }',
        '    if (-not $found) { $c = @($c) + "${k}=${v}" }',
        '    Set-Content -Path $StateFile -Value $c -Encoding UTF8',
        '}',
        "",
        'Log-Au "Iniciando verificacao automatica (ambiente=$DfeAmbiente)..."',
        "",
        '$DfeService    = Read-State "DFE_SERVICE_NAME"',
        '$DfeJarName    = Read-State "DFE_JAR_NAME"',
        '$DfeConfigName = Read-State "DFE_CONFIG_NAME"',
        '$OldVer        = Read-State "DFE_VERSAO"',
        '$ConfigFile    = Join-Path $InstallDir $(if ($DfeConfigName) { $DfeConfigName } else { "config.properties" })',
        '$JarPath       = Join-Path $InstallDir $DfeJarName',
        '$Tenant        = (Get-Content $ConfigFile -ErrorAction SilentlyContinue | Where-Object { $_ -match "^sync.tenant=" } | Select-Object -First 1) -replace "^sync.tenant=",""',
        '$Servidor      = [System.Net.Dns]::GetHostName()',
        "",
        'if ([string]::IsNullOrWhiteSpace($DfeService) -or [string]::IsNullOrWhiteSpace($JarPath)) {',
        '    Log-Au "ERRO: estado da instalacao incompleto - abortando."',
        '    exit 1',
        '}',
        "",
        '$BackupJar = "${JarPath}.bak"',
        'if (Test-Path $JarPath) { Copy-Item $JarPath $BackupJar -Force }',
        "",
        '$TmpDir = Join-Path $env:TEMP "dfe-autoupdate-$([System.IO.Path]::GetRandomFileName())"',
        'New-Item -Path $TmpDir -ItemType Directory -Force | Out-Null',
        '$UpdateRc = 1',
        'try {',
        '    $TmpScript = Join-Path $TmpDir "dfe-update.ps1"',
        '    Invoke-WebRequest -Uri $UpdateScriptUrl -OutFile $TmpScript -UseBasicParsing -ErrorAction Stop',
        '    & powershell -NoProfile -ExecutionPolicy Bypass -File $TmpScript -ApiUrl $TrackerApiUrl -Ambiente $DfeAmbiente -InstallDir $InstallDir -Yes',
        '    $UpdateRc = $LASTEXITCODE',
        '} catch {',
        '    Log-Au "ERRO: falha ao baixar/executar script de atualizacao: $_"',
        '    $UpdateRc = 1',
        '} finally {',
        '    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue',
        '}',
        "",
        '$NewVer     = Read-State "DFE_VERSAO"',
        '$Status     = "SUCESSO"',
        '$Descricao  = ""',
        "",
        'if ($UpdateRc -ne 0) {',
        '    $Status    = "ERRO"',
        '    $Descricao = "dfe-update.ps1 falhou com rc=$UpdateRc"',
        '    Log-Au $Descricao',
        '    if (Test-Path $BackupJar) {',
        '        Log-Au "Restaurando backup e reiniciando servico..."',
        '        Copy-Item $BackupJar $JarPath -Force',
        '        Write-StateVal "DFE_VERSAO" $OldVer',
        '        try {',
        '            $nssmPath = Join-Path $InstallDir "nssm.exe"',
        '            if (Test-Path $nssmPath) { & $nssmPath restart $DfeService }',
        '            else { Restart-Service -Name $DfeService -Force }',
        '            $Status    = "ROLLBACK"',
        '            $Descricao = "Rollback para v$OldVer realizado apos falha (rc=$UpdateRc)"',
        '        } catch { $Descricao = "Rollback tentado mas falha ao reiniciar servico" }',
        '    }',
        '} else {',
        '    Start-Sleep -Seconds 8',
        '    $svc = Get-Service -Name $DfeService -ErrorAction SilentlyContinue',
        '    if (-not $svc -or $svc.Status -ne "Running") {',
        '        Log-Au "Servico nao iniciou apos atualizacao. Realizando rollback..."',
        '        $Status    = "ROLLBACK"',
        '        $Descricao = "Servico nao iniciou apos atualizacao para v$NewVer. Rollback para v$OldVer realizado."',
        '        if (Test-Path $BackupJar) {',
        '            Copy-Item $BackupJar $JarPath -Force',
        '            Write-StateVal "DFE_VERSAO" $OldVer',
        '        }',
        '        try {',
        '            $nssmPath = Join-Path $InstallDir "nssm.exe"',
        '            if (Test-Path $nssmPath) { & $nssmPath restart $DfeService }',
        '            else { Restart-Service -Name $DfeService -Force -ErrorAction SilentlyContinue }',
        '        } catch {}',
        '        $NewVer = $OldVer',
        '    }',
        '}',
        "",
        'Remove-Item $BackupJar -Force -ErrorAction SilentlyContinue',
        'Log-Au "Resultado: status=$Status versao_anterior=$OldVer versao_nova=$NewVer"',
        "",
        'if (-not [string]::IsNullOrWhiteSpace($Tenant) -and -not [string]::IsNullOrWhiteSpace($TrackerApiUrl)) {',
        '    $DataIso   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")',
        '    $Desc      = "v$OldVer -> v$NewVer"',
        '    if ($Descricao) { $Desc = "$Desc | $Descricao" }',
        '    $DescSafe  = $Desc -replace "\"","\\"""',
        '    $Payload   = "{""tenant"":""$Tenant"",""modulo"":""AUTO_UPDATE"",""status"":""$Status"",""versao"":""$NewVer"",""nomeArquivo"":""$DfeService"",""rotaInterceptada"":""$DfeAmbiente"",""rotaRedirecionada"":""$Servidor"",""descricaoStatus"":""$DescSafe"",""data"":""$DataIso""}"',
        '    try {',
        '        Invoke-WebRequest -Uri $ReportApiUrl -Method Post -ContentType "application/json" -Body $Payload -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null',
        '    } catch { Log-Au "AVISO: falha ao enviar relatorio de atualizacao" }',
        '} else {',
        '    Log-Au "AVISO: tenant nao configurado - relatorio de atualizacao nao enviado"',
        '}',
        "",
        'Log-Au "Concluido (status=$Status, rc=$UpdateRc)"',
        'exit $UpdateRc'
    )

    Set-Content -Path $DFE_AUTOUPDATE_SCRIPT -Value $lines -Encoding UTF8
    Write-Host "  Script gerado: $DFE_AUTOUPDATE_SCRIPT" -ForegroundColor Green
}

function Register-AutoUpdateTask {
    param(
        [string]$TaskName,
        [string]$Description,
        $Trigger
    )
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -NonInteractive -File `"$DFE_AUTOUPDATE_SCRIPT`""
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $Trigger `
        -Settings $settings -Principal $principal -Description $Description -Force | Out-Null

    Write-Host ""
    Write-Host "  Auto-update ATIVADO: $Description" -ForegroundColor Green
    Write-Host "  Tarefa  : $TaskName"
    Write-Host "  Script  : $DFE_AUTOUPDATE_SCRIPT"
}

function Do-AutoUpdate {
    Ensure-ApiUrl

    # Detect installation for autoupdate dir
    $installDir = Select-InstallDir
    if ($null -eq $installDir) {
        Write-Host "  AVISO: Nenhuma instalacao valida encontrada. Usando diretorio padrao." -ForegroundColor Yellow
        $installDir = if ($script:DfeAmbiente -eq "PROD") { "C:\DFE_CONVERTER_PROD" } else { "C:\DFE_CONVERTER_QA" }
    }

    Show-AutoUpdateStatus

    $taskName = "$DFE_AUTOUPDATE_TASK_PREFIX-$($script:DfeAmbiente)"
    $descBase = "DFe auto-update $($script:DfeAmbiente)"

    Write-Host "  1) Ativar - Todo dia as 01:00"
    Write-Host "  2) Ativar - Toda segunda-feira as 01:00"
    Write-Host "  3) Ativar - Personalizado"
    Write-Host "  4) Desativar auto-update"
    Write-Host "  5) Voltar"
    Write-Host ""

    $choice = Read-Host "Escolha (1-5)"
    switch ($choice) {
        '1' {
            Write-AutoUpdateScript -InstallDir $installDir
            $trigger = New-ScheduledTaskTrigger -Daily -At "01:00"
            Register-AutoUpdateTask -TaskName $taskName -Description "$descBase diario 01:00" -Trigger $trigger
        }
        '2' {
            Write-AutoUpdateScript -InstallDir $installDir
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At "01:00"
            Register-AutoUpdateTask -TaskName $taskName -Description "$descBase segunda-feira 01:00" -Trigger $trigger
        }
        '3' {
            Write-Host ""
            Write-Host "  Horario (formato HH:mm, ex: 02:30):"
            $timeStr = Read-Host "  Horario"
            if ([string]::IsNullOrWhiteSpace($timeStr)) { Write-Host "  Cancelado."; return }
            Write-Host "  Frequencia:"
            Write-Host "    1) Todo dia"
            Write-Host "    2) Toda semana (segunda-feira)"
            $freqChoice = Read-Host "  Escolha (1-2)"
            Write-AutoUpdateScript -InstallDir $installDir
            $trigger = if ($freqChoice -eq '2') {
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $timeStr
            } else {
                New-ScheduledTaskTrigger -Daily -At $timeStr
            }
            Register-AutoUpdateTask -TaskName $taskName -Description "$descBase personalizado" -Trigger $trigger
        }
        '4' {
            $tasks = Get-ScheduledTask -TaskName "${DFE_AUTOUPDATE_TASK_PREFIX}*" -ErrorAction SilentlyContinue
            if ($tasks) {
                foreach ($task in $tasks) {
                    Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Host "  Tarefa '$($task.TaskName)' removida." -ForegroundColor Green
                }
            } else {
                Write-Host "  Nenhuma tarefa de auto-update encontrada."
            }
            $removeScript = Read-Host "  Remover tambem o script $DFE_AUTOUPDATE_SCRIPT? [y/N]"
            if ($removeScript -match '^[yYsS]') {
                if (Test-Path $DFE_AUTOUPDATE_SCRIPT) {
                    Remove-Item $DFE_AUTOUPDATE_SCRIPT -Force
                    Write-Host "  Script removido." -ForegroundColor Green
                }
            }
            Write-Host "  Auto-update DESATIVADO." -ForegroundColor Green
        }
        '5' { return }
        default { Write-Host "  Opcao invalida." -ForegroundColor Red }
    }
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

function Read-Menu {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "                   MENU PRINCIPAL                         " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1) Instalar service"
    Write-Host "  2) Remover service"
    Write-Host "  3) Reinstalar service (manter EXE/config)"
    Write-Host "  4) Status do service"
    Write-Host "  5) Listar servicos dfe instalados"
    Write-Host "  6) Verificar atualizacao"
    Write-Host "  7) Baixar e atualizar EXE"
    Write-Host "  8) Configurar auto-update"
    Write-Host "  9) Sair"
    Write-Host ""
    $choice = Read-Host "Escolha (1-9)"
    return $choice
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

Ensure-Elevated
Show-Banner

Write-Host "Inicializando..." -ForegroundColor Yellow
Write-Host ""

while ($true) {
    $opt = Read-Menu
    switch ($opt) {
        '1' { Do-Install }
        '2' { Do-Uninstall }
        '3' { Do-ReinstallService }
        '4' { Do-Status }
        '5' { Do-ListServices }
        '6' { Do-CheckUpdate }
        '7' { Do-Update }
        '8' { Do-AutoUpdate }
        '9' {
            Write-Host ""
            Write-Host "Encerrando.  Ate logo!" -ForegroundColor Green
            Write-Host ""
            exit 0
        }
        default { Write-Host "Opcao invalida." -ForegroundColor Red }
    }
    Write-Host ""
    Write-Host "----------------------------------------------------------"
    Read-Host "Pressione ENTER para continuar"
    Show-Banner
}
