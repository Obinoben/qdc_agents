################################################ Snap-ins
# Charger le snap-in Veeam
asnp "VeeamPSSnapIn" -ErrorAction SilentlyContinue
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

################################################ Variables
# Chemin vers la config (relatif ou absolu)
$configPath = "$PSScriptRoot\config.json"

################################################ Code - Fonctions
function ConvertTo-Hashtable {
    param(
        [Parameter(Mandatory=$true)]
        $InputObject
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($key in $InputObject.Keys) {
            $ht[$key] = ConvertTo-Hashtable $InputObject[$key]
        }
        return $ht
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and
            -not ($InputObject -is [string])) {
        return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    elseif ($InputObject -is [PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $ht
    }
    else {
        return $InputObject
    }
}

function Get-JobGap {
    param([Veeam.Backup.Core.CBackupJob]$job)

    $schedule = $job.ScheduleOptions
    if ($schedule.OptionsDaily -and $schedule.OptionsDaily.Enabled) {
        # Extraire les jours
        $daysOnly = $schedule.OptionsDaily.DaysSrv

        # Mapper les jours vers leur index dans la semaine
        $dayMap = @{
            Sunday = 0; Monday = 1; Tuesday = 2; Wednesday = 3;
            Thursday = 4; Friday = 5; Saturday = 6
        }

        # Ordre des jours sélectionnés
        $dayIndexes = $daysOnly | ForEach-Object { $dayMap[$_.ToString()] } | Sort-Object

        # Calcul des écarts (wrap-around inclus)
        $intervals = @()
        for ($i = 0; $i -lt $dayIndexes.Count; $i++) {
            $current = $dayIndexes[$i]
            $next = if ($i -eq $dayIndexes.Count - 1) {
                $dayIndexes[0] + 7  # boucle semaine suivante
            } else {
                $dayIndexes[$i + 1]
            }
            $intervals += ($next - $current)
        }

        # Récupérer l'écart maximal
        $maxGap = ($intervals | Measure-Object -Maximum).Maximum
        return $maxGap
    }

    elseif ($schedule.OptionsPeriodically -and $schedule.OptionsPeriodically.Enabled) {
        $hours = $schedule.OptionsPeriodically.RepeatEvery
        return [math]::Round($hours / 24, 2)
    }

    elseif ($schedule.OptionsMonthly -and $schedule.OptionsMonthly.Enabled) {
        return 30  # approximation
    }

    else {
        return 0
    }
}

function Get-JobDaysMap {
    param([Veeam.Backup.Core.CBackupJob]$job)

    $startTime = $rootJob.Info.ScheduleOptions.StartDateTimeLocal.ToString("HH:mm")

    $allDays = @("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
    $enabledDays = @()

    $schedule = $job.ScheduleOptions
    if ($schedule.OptionsDaily -and $schedule.OptionsDaily.Enabled) {
        $enabledDays = $schedule.OptionsDaily.DaysSrv # | ForEach-Object { $_.ToString().ToLower() }
    }

    $map = @{}
    foreach ($day in $allDays) {
        if ($enabledDays -contains $day) {
            $map[$day.ToLower()] = $startTime
        } else {
            $map[$day.ToLower()] = $null
        }
    }

    return $map
}


function Get-RootJobRec {
    param([string]$jobId)

    $job = Get-VBRJob | Where-Object { $_.Id -eq $jobId }
    if ($job.ScheduleOptions.OptionsScheduleAfterJob -and $job.ScheduleOptions.OptionsScheduleAfterJob.IsEnabled) {
        $parent = Get-VBRJob | Where-Object { $_.Id -eq $job.PreviousJobIdInScheduleChain }
        return Get-RootJobRec -jobId $parent.Id
    }
    return $job
}

function Get-RootJobBySession {
    param([Veeam.Backup.Core.CBackupSession]$session)

    $parts = $session.OrigJobName -split '\\'
    $rootJob = $parts[-1]
    $job = Get-VBRJob | Where-Object { $_.Name -eq $rootJob }
    if ($job) {
        return Get-RootJobRec -jobId $job.Id
    }

    return $null
}

function Get-MonitorID {
    param([PSCustomObject]$this_backup)

    Write-Host "BACKUP =" $this_backup.vm

    # Assurer que la clé de type existe
    if (-not $config.backups.ContainsKey($this_backup.type)) {
        $config.backups[$this_backup.type] = @{}
    }

    $typeDict = $config.backups[$this_backup.type]

    # Vérifier si la VM existe déjà
    if ($typeDict.ContainsKey($this_backup.vm)) {
        return $typeDict[$this_backup.vm]
    }

    # Construire la requette pour n8n
    $body = @{
        customer_name       = $config.client
        customer_shortname  = $config.client_shortname
        name                = $this_backup.vm
        type                = $this_backup.type
        base                = "Backups"
        gap                 = $this_backup.gap
    }
    # Envoyer à n8n
    try {
        $response = Invoke-RestMethod -Method POST `
            -Uri $config.n8nWebhookUrl `
            -Body ($body | ConvertTo-Json -Depth 10) `
            -ContentType "application/json"
    }
    catch {
        Write-Host "Erreur lors de l'appel du webhook n8n : $_"
        return $null
    }
    $responseItem = $response[0]
    Write-Host $responseItem
    # Stocker le push_token uniquement si il n'est pas null
    if ($responseItem.push_token) {
        $config.backups[$this_backup.type][$this_backup.vm] = $responseItem.push_token
        return $responseItem.push_token
    }
    else {
        Write-Host "Aucun push_token reçu pour $($this_backup.vm)"
        return $null
    }
}

################################################ Code
# Exemple de configuration
$defaultConfig = @{
    client  = "Change Me"
    client_shortname = "ChangeMe"
    kumaUrl = "https://status.quadrumane.com/api/push/"
    n8nWebhookUrl = "https://automate.quadrumane.com/webhook/74dfd527-910a-47c5-83fa-6c6826835586"
    backups = @{}
}
# Si le fichier n'existe pas, on le crée avec un exemple
if (-not (Test-Path $configPath)) {
    $defaultConfig | ConvertTo-Json -Depth 2 | Out-File -Encoding UTF8 $configPath
    Write-Host "Fichier de configuration créé à : $configPath"
    Write-Host "Veuillez le remplir avant de relancer ce script."
    exit 1
}
# Charger la configuration
try {
    $configJson = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Error "Le fichier $configPath est invalide. Corrigez le JSON."
    exit 1
}
$config = ConvertTo-Hashtable $configJson
# Vérifier que tous les champs sont renseignés
if ($config.client -eq "Change Me" -or $config.client_shortname -eq "ChangeMe") {
    Write-Warning "Le fichier de configuration doit être complété avant usage."
    exit 1
}

# S'assurer que backups existe et est un Hashtable
if (-not $config.ContainsKey('backups')) {
    $config.backups = @{}
}

# Convertir backups en Hashtable pour accès facile
if ($config.backups -isnot [hashtable]) {
    $ht = @{}
    foreach ($p in $config.backups.PSObject.Properties) {
        $ht[$p.Name] = $p.Value
    }
    $config.backups = $ht
}

# Sessions de backup des dernières 48h
$vbrSessions = Get-VBRBackupSession | Where-Object { $_.EndTime -ge (Get-Date).AddHours(-48) }

# Dictionnaire avec clé VM|Type
$vmDict = @{}

foreach ($session in $vbrSessions) {
    $JobStatus = $session.Status

    # Mapping type
    $rawType = ([Veeam.Backup.Model.EDbJobType]$session.JobType).ToString()
    switch ($rawType) {
        "Backup" { $type = "Local" }
        "Replica" { $type = "Replica" }
        "SimpleBackupCopyWorker" { $type = "HorsSite" }
    }
    # Status
    $status = $session.Result
    if ($status -eq "None") {
        $status = $JobStatus
    }

    # Root Job schedule
    $rootJob = Get-RootJobBySession -session $session
    if ($null -eq $rootJob) {
        Write-Warning "Job introuvable pour session : $($session.OrigJobName)"
        continue
    }
    $maxGap = Get-JobGap -job $rootJob
    $schedule = Get-JobDaysMap -job $rootJob

    # VM Loop
    foreach ($vm in ($session.GetTaskSessions())) {
        $hostname = $vm.Name
        $date = $session.EndTime

        # Format date
        if ($date -match '\/Date\((\d+)\)\/') {
            $timestamp = [long]($matches[1] / 1000)
            $date = [datetime]::new(1970, 1, 1).AddSeconds($timestamp).ToLocalTime()
        }
        $formattedDate = $date.ToString("yyyy-MM-dd H:mm:ss")

        # Clé composite VM + Type
        $key = "$hostname|$type"

        #Write-Output "$key : $formattedDate"

        # Met à  jour si plus récent
        if ($vmDict.ContainsKey($key)) {
            $currentDate = [datetime]::ParseExact($vmDict[$key].date, "yyyy-MM-dd H:mm:ss", $null)
            if ([datetime]::ParseExact($formattedDate, "yyyy-MM-dd H:mm:ss", $null) -gt $currentDate) {
                $vmDict[$key] = @{
                    vm     = $hostname
                    date   = $formattedDate
                    type   = $type
                    result = $status
                    days   = $schedule
                    gap = $maxGap
                }
            }
        } else {
            $vmDict[$key] = @{
                vm     = $hostname
                date   = $formattedDate
                type   = $type
                result = $status
                days   = $schedule
                gap = $maxGap
            }
        }
    }
}

# Construction du JSON
$jsonArray = $vmDict.Values
$jsonOutput = @{
    client        = $config.client
    backups_type  = "veeam"
    backups       = $jsonArray
}
$jsonString = $jsonOutput | ConvertTo-Json -Depth 10
# Write-Output $jsonString

# Appelle le moniteur Kuma
$now = Get-Date
# Itération
foreach ($backup in $jsonOutput.backups) {
    $Url_Code = Get-MonitorID -this_backup $backup

    $backupDate = [datetime]$backup.date
    $age = $now - $backupDate
    $ageHours = [math]::Floor($age.TotalHours)
    $ageTolerance = (1.5 * $backup.gap) * 24
    if ($ageHours -lt $ageTolerance -and $backup.result -eq 0) {
        $status = "up"
    }
    else {
        $status = "down"
    }
    $msg = [System.Web.HttpUtility]::UrlEncode($backup.date)

    # Construire l'URL (exemple)
    $url = $config.kumaUrl + $Url_Code + "?status=" + $status + "&msg=" + $msg + "&ping=" + $ageHours

    Write-Host "Envoi vers $url"

    # Envoi "fire and forget" sans attendre réponse
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "PowerShell")
        $wc.DownloadString($url)
    }
    catch {
        Write-Warning "Erreur d'envoi : $_"
    }
}

# Réécrire la config mise à jour dans le fichier JSON
$config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
