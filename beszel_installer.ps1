#Requires -RunAsAdministrator
<#
    Installation de l'agent Beszel pour Windows
    Usage (compatible commande beszel) :
      & iwr -useb https://votre-serveur/beszel_installer.ps1 -OutFile "$env:TEMP\install-agent.ps1"
      & Powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-agent.ps1" `
            -Key "ssh-ed25519 AAAAC..." -Port 45876 -Token "xxxx" -Url "https://bes.exemple.com"

    Tous les parametres sont optionnels : le script demande les valeurs manquantes de facon interactive.
#>

param(
    [string]$Key,
    [int]$Port    = 0,
    [string]$Token,
    [string]$Url
)

# ---------- Constantes ----------
$InstallDir  = "C:\Program Files\beszel-agent"
$ExePath     = Join-Path $InstallDir "beszel-agent.exe"
$ServiceName = "beszel-agent"
$Arch        = "amd64"
$DownloadUrl = "https://github.com/henrygd/beszel/releases/latest/download/beszel-agent_windows_$Arch.zip"
$ConfigPath  = Join-Path $InstallDir "config.json"

# ---------- Saisie interactive pour les valeurs manquantes ----------
Write-Host "=== Installation de l'agent Beszel ===" -ForegroundColor Cyan

# Reprise de la configuration existante pour les parametres non fournis en CLI
if (Test-Path $ConfigPath) {
    try {
        $cfg        = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $fromConfig = @()
        if ([string]::IsNullOrWhiteSpace($Key)   -and $cfg.Key)   { $Key   = $cfg.Key;        $fromConfig += 'Key' }
        if ($Port -eq 0                           -and $cfg.Port)  { $Port  = [int]$cfg.Port;  $fromConfig += 'Port' }
        if ([string]::IsNullOrWhiteSpace($Url)   -and $cfg.Url)   { $Url   = $cfg.Url;        $fromConfig += 'Url' }
        if ([string]::IsNullOrWhiteSpace($Token) -and $cfg.Token) { $Token = $cfg.Token;      $fromConfig += 'Token' }
        if ($fromConfig) {
            Write-Host "Parametres repris depuis la configuration existante ($($fromConfig -join ', ')) :" -ForegroundColor DarkCyan
            Write-Host "  Hub  : $Url"
            Write-Host "  Port : $Port"
        }
    } catch {
        Write-Host "Fichier de configuration existant illisible, saisie requise." -ForegroundColor Yellow
    }
}

if ([string]::IsNullOrWhiteSpace($Url)) {
    $Url = Read-Host "URL du hub (ex: https://bes.exemple.com)"
}
if ([string]::IsNullOrWhiteSpace($Key)) {
    $Key = Read-Host "Cle SSH du hub (ssh-ed25519 ...)"
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = Read-Host "Token d'authentification"
}
if ($Port -eq 0) {
    $portInput = Read-Host "Port d'ecoute de l'agent (Entree = 45876)"
    $Port = if ([string]::IsNullOrWhiteSpace($portInput)) { 45876 } else { [int]$portInput }
}

if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($Key) -or [string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "Url, Key ou Token manquant. Abandon." -ForegroundColor Red
    exit 1
}

# ---------- Preparation ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Suppression de l'ancien service Windows..." -ForegroundColor Yellow
    sc.exe stop $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}
if (Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Suppression de l'ancienne tache planifiee..." -ForegroundColor Yellow
    Stop-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Sauvegarde de la configuration pour les reinstallations futures
@{ Key = $Key; Port = $Port; Url = $Url; Token = $Token } |
    ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8

# ---------- Telechargement ----------
$ZipPath = Join-Path $env:TEMP "beszel-agent.zip"
Write-Host "Telechargement de l'agent..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing
} catch {
    Write-Host "Echec du telechargement : $_" -ForegroundColor Red
    exit 1
}

# ---------- Extraction ----------
Write-Host "Extraction..." -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression.FileSystem
$TempExtract = Join-Path $env:TEMP ("beszel-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempExtract | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $TempExtract)
Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue

$found = Get-ChildItem -Path $TempExtract -Filter "*.exe" -Recurse | Select-Object -First 1
if ($found) {
    Get-Process -Name $ServiceName -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    Remove-Item -Path $ExePath -Force -ErrorAction SilentlyContinue
    Move-Item $found.FullName $ExePath
} else {
    Write-Host "Executable introuvable apres extraction." -ForegroundColor Red
    exit 1
}
Remove-Item $TempExtract -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Creation de la tache planifiee ----------
Write-Host "Creation de la tache planifiee..." -ForegroundColor Cyan

# Script wrapper statique : lit config.json au demarrage, pas de valeurs en dur.
$WrapperPath = Join-Path $InstallDir "start-agent.ps1"
@'
$cfg         = Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json
$env:KEY     = $cfg.Key
$env:PORT    = [string]$cfg.Port
$env:HUB_URL = $cfg.Url
$env:TOKEN   = $cfg.Token

$logFile   = "$PSScriptRoot\beszel-agent.log"
$agentOut  = "$PSScriptRoot\beszel-agent-output.log"

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Test-AgentStuck {
    param([string]$Path, [int]$GraceMinutes = 3)

    if (-not (Test-Path $Path)) { return $false }

    try { $tail = Get-Content $Path -Tail 60 -ErrorAction Stop } catch { return $false }
    if (-not $tail) { return $false }

    $lastGoodIdx = -1
    $lastBadIdx  = -1
    for ($i = 0; $i -lt $tail.Count; $i++) {
        if ($tail[$i] -match "WebSocket connected")                              { $lastGoodIdx = $i }
        if ($tail[$i] -match "WebSocket connection failed|Disconnected from hub") { $lastBadIdx  = $i }
    }

    if ($lastBadIdx -lt 0) { return $false }                # jamais eu de souci recent
    if ($lastGoodIdx -gt $lastBadIdx) { return $false }      # reconnecte depuis -> ok

    if ($tail[$lastBadIdx] -match '^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})') {
        $ts = [datetime]::ParseExact($matches[1], "yyyy/MM/dd HH:mm:ss", $null)
        return ((Get-Date) - $ts) -gt (New-TimeSpan -Minutes $GraceMinutes)
    }
    return $false
}

if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
    Move-Item $logFile "$logFile.old" -Force
}

Write-Log "INFO" "Watchdog demarre"

while ($true) {
    $proc = Start-Process -FilePath "$PSScriptRoot\beszel-agent.exe" `
                           -RedirectStandardOutput $agentOut `
                           -RedirectStandardError "$agentOut.err" `
                           -PassThru -NoNewWindow
    Write-Log "START" "Agent demarre (PID $($proc.Id))"

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 60
        if (Test-AgentStuck -Path $agentOut -GraceMinutes 3) {
            Write-Log "STUCK" "Pas de reconnexion depuis 3+ min - kill force (PID $($proc.Id))"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            break
        }
    }

    Write-Log "EXIT" "Agent termine (code : $($proc.ExitCode)) - redemarrage dans 5s"
    Start-Sleep -Seconds 5
}
'@ | Set-Content -Path $WrapperPath -Encoding UTF8

$action    = New-ScheduledTaskAction `
                 -Execute   "powershell.exe" `
                 -Argument  "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WrapperPath`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet `
                 -ExecutionTimeLimit ([TimeSpan]::Zero) `
                 -RestartCount 3 `
                 -RestartInterval (New-TimeSpan -Minutes 1) `
                 -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName    $ServiceName `
                       -Action      $action `
                       -Trigger     $trigger `
                       -Settings    $settings `
                       -Principal   $principal `
                       -Description "Agent de monitoring Beszel" `
                       -Force | Out-Null

# ---------- Demarrage ----------
Write-Host "Demarrage de la tache..." -ForegroundColor Cyan
Start-ScheduledTask -TaskName $ServiceName
Start-Sleep -Seconds 3

# ---------- Verification ----------
$task = Get-ScheduledTask     -TaskName $ServiceName -ErrorAction SilentlyContinue
$info = Get-ScheduledTaskInfo -TaskName $ServiceName -ErrorAction SilentlyContinue
if ($task -and $task.State -eq "Running") {
    Write-Host "`nOK - L'agent Beszel est installe et demarre." -ForegroundColor Green
    Write-Host "Dossier : $InstallDir"
    Write-Host "Hub     : $Url"
    Write-Host "Port    : $Port"
} else {
    $lastCode = if ($info) { "0x{0:X8}" -f $info.LastTaskResult } else { "inconnu" }
    Write-Host "`nTache creee mais non demarree (etat: $($task.State), code: $lastCode)." -ForegroundColor Red
    Write-Host "Testez le binaire directement dans une console admin :" -ForegroundColor Yellow
    Write-Host "  `$env:KEY='$Key'; `$env:PORT='$Port'; `$env:HUB_URL='$Url'; `$env:TOKEN='$Token'" -ForegroundColor Gray
    Write-Host "  & '$ExePath'" -ForegroundColor Gray
    Write-Host "Journal du planificateur :" -ForegroundColor Yellow
    Write-Host "  Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 20" -ForegroundColor Gray
}
