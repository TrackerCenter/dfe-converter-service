<#
dfe-install.ps1 - Instalador de service Windows (usa nssm se necessario).
Execute em PowerShell ELEVADO no diretorio do instalador ou forneca -InstallDir.
#>
param(
    [string]$InstallDir   = $PSScriptRoot,
    [string]$ConfigName   = "config.properties",
    [string]$Description  = "J2R Consultoria - Conversao de documentos fiscais.",
    [string]$NssmVersion  = "2.24",
    [string]$JarName      = "",
    [string]$Ambiente     = "",
    [string]$ServiceName  = "",
    [string]$DisplayName  = "",
    [string]$Versao       = "",
    [switch]$EnableAppLogs
)

try { chcp 65001 > $null 2>&1 } catch {}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Log {
    param($m)
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $m" | Tee-Object -FilePath (Join-Path $InstallDir 'script-install.log') -Append
}

if (-not ([bool](net session 2>$null))) {
    Write-Error "Execute este script em PowerShell 'Como Administrador'."
    exit 1
}

$InstallDir = (Resolve-Path -Path $InstallDir).Path

function Read-EnvChoice {
    while ($true) {
        Write-Host ""
        Write-Host "Escolha o ambiente / versao a instalar:"
        Write-Host "  1) QA"
        Write-Host "  2) PROD"
        Write-Host "  3) Outro (digite valores manualmente)"
        $c = Read-Host "Digite a opcao (1/2/3)"
        switch ($c) {
            '1' { return 'QA' }
            '2' { return 'PROD' }
            '3' { return 'OTHER' }
            default { Write-Host "Opcao invalida.  Tente novamente." }
        }
    }
}

function PromptWithDefault([string]$prompt, [string]$default) {
    $r = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $default } else { return $r.Trim() }
}

# When called from dfe-setup.ps1, all params are already provided — skip interactive prompts
$paramsProvided = (-not [string]::IsNullOrWhiteSpace($JarName)) -and
                  (-not [string]::IsNullOrWhiteSpace($Ambiente)) -and
                  (-not [string]::IsNullOrWhiteSpace($ServiceName)) -and
                  (-not [string]::IsNullOrWhiteSpace($DisplayName))

if ($paramsProvided) {
    $envChoice = $Ambiente.ToUpper()
    Write-Host "Ambiente selecionado: $envChoice"
} else {
    $envChoice = Read-EnvChoice

    if ($envChoice -eq 'QA') {
        $defaultJar = "DFe-Converter-QA.exe"
        $defaultService = "DFeConverterQA"
        $defaultDisplay = "DF-e Converter QA"
        Write-Host "Ambiente selecionado: QA"
        $JarName     = PromptWithDefault "Nome do JAR" $defaultJar
        $ServiceName = PromptWithDefault "ServiceName (nome do servico Windows)" $defaultService
        $DisplayName = PromptWithDefault "DisplayName (nome exibido em Services.msc)" $defaultDisplay
    }
    elseif ($envChoice -eq 'PROD') {
        $defaultJar = "DFe-Converter-PROD.exe"
        $defaultService = "DFeConverterPROD"
        $defaultDisplay = "DF-e Converter PROD"
        Write-Host "Ambiente selecionado: PROD"
        $JarName     = PromptWithDefault "Nome do JAR" $defaultJar
        $ServiceName = PromptWithDefault "ServiceName (nome do servico Windows)" $defaultService
        $DisplayName = PromptWithDefault "DisplayName (nome exibido em Services.msc)" $defaultDisplay
    }
    else {
        Write-Host "Ambiente selecionado: Outro"
        $JarName = Read-Host "Digite o nome do JAR (ex.: DFe-Converter-QA.jar)"
        if ([string]::IsNullOrWhiteSpace($JarName)) { Write-Host "Nome do JAR obrigatorio.  Abortando. "; exit 2 }
        $ServiceName = Read-Host "Digite o ServiceName (nome do servico Windows)"
        if ([string]::IsNullOrWhiteSpace($ServiceName)) { Write-Host "ServiceName obrigatorio. Abortando."; exit 2 }
        $DisplayName = Read-Host "Digite o DisplayName (nome exibido em Services.msc)"
        if ([string]::IsNullOrWhiteSpace($DisplayName)) { Write-Host "DisplayName obrigatorio. Abortando."; exit 2 }
    }
}

$javaExe = Join-Path $InstallDir "java\bin\java.exe"
$jarPath = Join-Path $InstallDir $JarName
$configPath = Join-Path $InstallDir $ConfigName
$nssmExe = Join-Path $InstallDir "nssm.exe"
$logsDir = Join-Path $InstallDir "logs"
$stdout = Join-Path $logsDir "stdout.log"
$stderr = Join-Path $logsDir "stderr.log"

Log "Start nssm-install"
Log ("InstallDir: {0}" -f $InstallDir)
Log ("Jar: {0}" -f $jarPath)
Log ("Config: {0}" -f $configPath)
Log ("Local Java: {0}" -f $javaExe)
Log ("ServiceName: {0}" -f $ServiceName)
Log ("DisplayName: {0}" -f $DisplayName)
Log ("Description: {0}" -f $Description)
if ($EnableAppLogs) {
    Log "Parametro -EnableAppLogs fornecido: logs SERAO configurados."
} else {
    Log "Por padrao logs NAO serao configurados."
}

if (-not (Test-Path $jarPath)) {
    Write-Error "JAR nao encontrado: $jarPath"
    Log ("JAR nao encontrado: {0}" -f $jarPath)
    exit 2
}

if (-not (Test-Path $javaExe)) {
    Log ("Java local nao encontrado em {0}.  Tentando usar 'java' do PATH." -f $javaExe)
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) {
        $javaExe = $cmd.Source
    } else {
        $javaExe = $null
    }
    if (-not $javaExe) {
        Write-Error "java nao encontrado localmente nem no PATH.  Coloque a JRE em $InstallDir\java ou instale a JRE no sistema."
        Log "java nao encontrado.  Abortando."
        exit 3
    } else {
        Log ("Usando java do PATH: {0}" -f $javaExe)
    }
}

if ($EnableAppLogs) {
    if (-not (Test-Path $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        Log ("Criada pasta de logs: {0}" -f $logsDir)
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

if (-not (Test-Path $nssmExe)) {
    Log ("nssm.exe nao encontrado em {0}. Tentando baixar nssm-{1}.zip..." -f $InstallDir, $NssmVersion)
    $zipUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
    $tmpZip = Join-Path $env:TEMP "nssm-$NssmVersion.zip"
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        $tmpExtract = Join-Path $env:TEMP "nssm-$NssmVersion"
        if (Test-Path $tmpExtract) {
            Remove-Item -Recurse -Force $tmpExtract
        }
        Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
        $candidate = Join-Path $tmpExtract "nssm-$NssmVersion\win64\nssm.exe"
        if (-not (Test-Path $candidate)) {
            $candidate = Get-ChildItem -Path $tmpExtract -Recurse -Filter nssm.exe | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($candidate -and (Test-Path $candidate)) {
            Copy-Item -Path $candidate -Destination $nssmExe -Force
            Log ("nssm.exe copiado para {0}" -f $nssmExe)
        } else {
            Write-Error "Nao encontrei nssm.exe dentro do zip. Baixe manualmente e coloque em $InstallDir"
            Log "Falha ao localizar nssm.exe no ZIP."
            exit 4
        }
    } catch {
        Write-Error ("Erro ao baixar/extrair nssm: {0}" -f $_.Exception.Message)
        Log ("Erro ao baixar/extrair nssm: {0}" -f $_.Exception.Message)
        exit 4
    } finally {
        if (Test-Path $tmpZip) {
            Remove-Item $tmpZip -Force
        }
    }
} else {
    Log ("nssm.exe ja presente: {0}" -f $nssmExe)
}

try {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Log "Servico existente detectado.  Tentando parar e remover..."
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
        & $nssmExe remove $ServiceName confirm | ForEach-Object { Log $_ }
    }
} catch {
    Log ("Aviso ao checar/remover servico existente: {0}" -f $_.Exception.Message)
}

$escapedJar = '"' + $jarPath + '"'
$escapedConfig = '"' + $configPath + '"'
$javaArgs = "-Dapp.headless=true -Djava.awt.headless=true -jar $escapedJar --sync.config.file=$escapedConfig"

Log ("Instalando servico via nssm: {0} install {1} {2} {3}" -f $nssmExe, $ServiceName, $javaExe, $javaArgs)
& $nssmExe install $ServiceName $javaExe $javaArgs | ForEach-Object { Log $_ }

if ($DisplayName) {
    Log ("Definindo DisplayName: {0}" -f $DisplayName)
    & $nssmExe set $ServiceName DisplayName $DisplayName | ForEach-Object { Log $_ }
}
if ($Description) {
    Log ("Definindo Description: {0}" -f $Description)
    & $nssmExe set $ServiceName Description $Description | ForEach-Object { Log $_ }
}

& $nssmExe set $ServiceName AppDirectory $InstallDir | ForEach-Object { Log $_ }

if ($EnableAppLogs) {
    & $nssmExe set $ServiceName AppStdout $stdout | ForEach-Object { Log $_ }
    & $nssmExe set $ServiceName AppStderr $stderr | ForEach-Object { Log $_ }
    & $nssmExe set $ServiceName AppRotateFiles 1 | ForEach-Object { Log $_ }
} else {
    Log "AppStdout/AppStderr NAO configurados."
}

& $nssmExe set $ServiceName Start SERVICE_AUTO_START | ForEach-Object { Log $_ }

Log ("Tentando iniciar servico {0} via nssm..." -f $ServiceName)
& $nssmExe start $ServiceName | ForEach-Object { Log $_ }
Start-Sleep -Seconds 3

try {
    $s = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($s.Status -eq 'Running') {
        Write-Host ("Servico '{0}' instalado e iniciado com sucesso." -f $DisplayName) -ForegroundColor Green
        Log "Servico iniciado com sucesso."
    } else {
        Write-Warning ("Servico instalado mas nao entrou em Running. Status: {0}" -f $s.Status)
        Log ("Servico instalado mas nao entrou em Running. Status: {0}" -f $s.Status)
    }
} catch {
    Write-Error ("Erro ao verificar status do servico: {0}" -f $_.Exception.Message)
    Log ("Erro ao verificar status do servico: {0}" -f $_.Exception.Message)
}

function Add-OrUpdate-InstallRecord {
    param($cfgPath, $record)
    if (Test-Path $cfgPath) {
        try {
            $data = Get-Content $cfgPath -Raw | ConvertFrom-Json
        } catch {
            $data = @{ installations = @() }
        }
    } else {
        $data = @{ installations = @() }
    }
    $existsIndex = $null
    for ($i=0; $i -lt $data.installations.Count; $i++) {
        $ent = $data.installations[$i]
        if ($ent.serviceName -eq $record.serviceName -or $ent.jarName -eq $record.jarName) {
            $existsIndex = $i
            break
        }
    }
    if ($existsIndex -ne $null) {
        $data.installations[$existsIndex] = $record
    } else {
        $data.installations += $record
    }
    $data | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path $cfgPath
    Write-Host "JSON state gravado em: $cfgPath"
}

# Write or update a single key in the .dfe-setup.env file (key=value format)
function Write-EnvState {
    param([string]$Key, [string]$Value, [string]$File)
    if (-not (Test-Path $File)) { New-Item -ItemType File -Path $File -Force | Out-Null }
    $content = @(Get-Content $File -ErrorAction SilentlyContinue)
    $found = $false
    $newContent = $content | ForEach-Object {
        if ($_ -match "^${Key}=") { "${Key}=${Value}"; $found = $true } else { $_ }
    }
    if (-not $found) { $newContent = @($newContent) + "${Key}=${Value}" }
    Set-Content -Path $File -Value $newContent -Encoding UTF8
}

$cfgPath = Join-Path $InstallDir ".dfe-setup.json"
$installedBy = $env:USERNAME
$installedAt = (Get-Date).ToString("o")

$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if ($javaCmd) {
    $javaPathUsed = $javaCmd.Source
} else {
    $javaPathUsed = $null
}

$record = @{
    serviceName = $ServiceName
    jarName = $JarName
    configName = $ConfigName
    javaPath = $javaPathUsed
    logsEnabled = [bool]$EnableAppLogs
    installDir = $InstallDir
    installedAt = $installedAt
    installedBy = $installedBy
    os = "windows"
}
Add-OrUpdate-InstallRecord -cfgPath $cfgPath -record $record

# Write .dfe-setup.env in key=value format (required by dfe-update.ps1)
$envPath = Join-Path $InstallDir ".dfe-setup.env"
$ambienteVal = if ($envChoice -eq 'PROD') { 'PROD' } elseif ($envChoice -eq 'QA') { 'QA' } else { '' }
Write-EnvState "DFE_SERVICE_NAME" $ServiceName $envPath
Write-EnvState "DFE_JAR_NAME"     $JarName     $envPath
Write-EnvState "DFE_CONFIG_NAME"  $ConfigName  $envPath
Write-EnvState "DFE_VERSAO"       $Versao      $envPath
Write-EnvState "DFE_AMBIENTE"     $ambienteVal $envPath
Write-EnvState "DFE_INSTALL_DIR"  $InstallDir  $envPath
Log ("ENV state gravado em: {0}" -f $envPath)
Write-Host "ENV state gravado em: $envPath"

Write-Host "Instalacao finalizada."
exit 0
