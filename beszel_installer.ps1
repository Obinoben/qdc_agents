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

# ---------- Saisie interactive pour les valeurs manquantes ----------
Write-Host "=== Installation de l'agent Beszel ===" -ForegroundColor Cyan

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
    Write-Host "Suppression de l'ancien service..." -ForegroundColor Yellow
    sc.exe stop $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

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
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $ExePath)) {
    $found = Get-ChildItem -Path $InstallDir -Filter "*.exe" -Recurse | Select-Object -First 1
    if ($found) {
        Move-Item $found.FullName $ExePath -Force
    } else {
        Write-Host "Executable introuvable apres extraction." -ForegroundColor Red
        exit 1
    }
}

# ---------- Creation du service ----------
Write-Host "Creation du service Windows..." -ForegroundColor Cyan

sc.exe create $ServiceName binPath= "`"$ExePath`"" start= auto DisplayName= "Beszel Agent" | Out-Null
sc.exe description $ServiceName "Agent de monitoring Beszel" | Out-Null

# Variables d'environnement injectees directement dans le registre du service
# (evite de polluer les variables machine)
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
New-ItemProperty -Path $regPath -Name "Environment" -PropertyType MultiString -Force -Value @(
    "KEY=$Key",
    "PORT=$Port",
    "HUB_URL=$Url",
    "TOKEN=$Token"
) | Out-Null

sc.exe failure $ServiceName reset= 0 actions= restart/5000/restart/5000/restart/5000 | Out-Null

# ---------- Demarrage ----------
Write-Host "Demarrage du service..." -ForegroundColor Cyan
Start-Sleep -Seconds 1
sc.exe start $ServiceName | Out-Null
Start-Sleep -Seconds 3

# ---------- Verification ----------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "`nOK - L'agent Beszel est installe et demarre." -ForegroundColor Green
    Write-Host "Dossier : $InstallDir"
    Write-Host "Hub     : $Url"
    Write-Host "Port    : $Port"
} else {
    Write-Host "`nService cree mais non demarre." -ForegroundColor Yellow
    Write-Host "Verifier avec  : Get-Service $ServiceName" -ForegroundColor Yellow
    Write-Host "Logs Windows   : Get-EventLog -LogName Application -Newest 20" -ForegroundColor Yellow
}
