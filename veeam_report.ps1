<#
.SYNOPSIS
    Supervision des sauvegardes Veeam vers Uptime Kuma (moniteurs push), avec creation
    automatique des moniteurs via n8n.

.DESCRIPTION
    Compatible Veeam Backup & Replication v11 et v12, Windows PowerShell 5.1.

    Sources (activables dans la config, section "sources") :
      - vm        : un moniteur par VM et par type (Backup, Replica, Backup Copy)
      - fileshare : un moniteur par job "File Backup" (partages SMB/NFS)

    Statut : "up" si le dernier succes est plus recent que (periodicite du job x toleranceFactor).
    Un job en cours n'est pas un echec : on garde le dernier resultat termine, qui finit par
    passer "down" s'il devient trop ancien. Le dernier resultat "Failed" passe "down"
    immediatement (evaluation.failedIsDown), ainsi que N warnings consecutifs
    (evaluation.maxConsecutiveWarnings).

    Seules les sessions terminees depuis le passage precedent sont lues (maxLookbackDays au
    plus) ; le dernier etat connu de chaque element est conserve dans veeam_state.json.

    Fichiers (dans le dossier de la config) :
      - config.json       : parametres (cree en version demo s'il n'existe pas)
      - veeam_state.json  : tokens Kuma et dernier etat connu par element (gere par le script)
      - veeam_report.log  : journal

.PARAMETER ConfigPath
    Chemin de la config. Par defaut : config.json a cote du script.

.PARAMETER StatePath
    Chemin du fichier d'etat. Par defaut : veeam_state.json a cote de la config.

.PARAMETER DryRun
    Collecte et evalue sans appeler n8n ni Kuma, sans ecrire l'etat.

.PARAMETER Diagnose
    Affiche les types de jobs et de sessions detectes et l'evaluation de chaque element.
    Implique -DryRun. A lancer apres une mise a jour Veeam ou sur une nouvelle version.

.PARAMETER Exclude
    Arrete la publication des elements indiques (nom de VM ou de job, exact) en les ajoutant
    a "exclude" dans config.json, puis quitte. L'etat et le token sont conserves.

.PARAMETER Include
    Reactive des elements exclus avec -Exclude, puis quitte.

.PARAMETER ResetMonitor
    Oublie le token Kuma des elements indiques ("Type/Nom", jokers acceptes) pour que le
    moniteur soit recree via n8n pendant cette execution. Exemples : 'Local/VM2',
    'Fichiers/*', '*' (tous). A utiliser apres la suppression d'un moniteur dans Kuma.

.NOTES
    Codes de sortie : 0 OK, 1 configuration, 2 Veeam indisponible, 3 deja en cours,
                      4 erreurs d'envoi, 5 erreur inattendue.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$StatePath,
    [switch]$DryRun,
    [switch]$Diagnose,
    [string[]]$ResetMonitor,
    [string[]]$Exclude,
    [string[]]$Include
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

################################################ Configuration par defaut
# Ecrite telle quelle comme config de demo si config.json n'existe pas.
# Une config existante est fusionnee avec ces valeurs : seules les cles a changer sont necessaires.
$DefaultConfig = @{
    client           = 'Change Me'
    client_shortname = 'ChangeMe'
    kuma = @{
        url        = 'https://status.quadrumane.com/api/push/'
        timeoutSec = 15
        retries    = 2
        maxConsecutiveFailures = 3   # Kuma considere injoignable : envois suivants abandonnes
    }
    n8n = @{
        webhookUrl = 'https://automate.quadrumane.com/webhook/74dfd527-910a-47c5-83fa-6c6826835586'
        timeoutSec = 30
    }
    evaluation = @{
        toleranceFactor  = 1.5    # tolerance = periodicite du job x facteur
        defaultGapDays   = 1      # periodicite si le planning est illisible (manuel, continu, chaine...)
        warningIsSuccess = $true  # un Warning compte comme un succes
        failedIsDown     = $true  # un dernier resultat Failed passe down sans attendre
        maxConsecutiveWarnings = 3  # N warnings d'affilee = echec (0 = desactive)
    }
    maxLookbackDays = 7           # analyse depuis le passage precedent, au plus N jours en arriere
    forgetAfterDays = 30          # element sans session depuis N jours : plus publie
    gapOverrides    = @{}         # { "Nom du job": 7 } force la periodicite en jours
    exclude         = @()         # regex sur le nom de l'element (VM ou job)
    sources = @{
        vm = @{
            enabled     = $true
            granularity = 'object'   # un moniteur par VM
            jobTypes    = @{ Backup = 'Local'; Replica = 'Replica'; SimpleBackupCopyWorker = 'HorsSite' }
        }
        fileshare = @{
            enabled     = $true
            granularity = 'job'      # un moniteur par job
            jobTypes    = @{ NasBackup = 'Fichiers'; NasBackupCopy = 'FichiersHorsSite' }
        }
    }
    logFile = 'veeam_report.log'
}

$ValidResults = @('Success', 'Warning', 'Failed')
$script:LogFile = $null

################################################ Utilitaires
function Write-ReportLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }
    if ($script:LogFile -and $Level -ne 'DEBUG') {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

$script:RunClock = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Step {
    # Etape principale, avec le temps ecoule depuis le demarrage
    param([string]$Message)
    Write-ReportLog ('[+{0,6:0.0}s] {1}' -f $script:RunClock.Elapsed.TotalSeconds, $Message)
}

function Initialize-Log {
    param([string]$Path, [long]$MaxBytes = 1MB)
    try {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt $MaxBytes) {
            Move-Item -Path $Path -Destination "$Path.old" -Force
        }
        $script:LogFile = $Path
    }
    catch {
        Write-Host "Journal indisponible ($Path) : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($key in $InputObject.Keys) { $ht[$key] = ConvertTo-Hashtable $InputObject[$key] }
        return $ht
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        # La virgule empeche PowerShell de deplier un tableau a un seul element
        return , @(foreach ($item in $InputObject) { ConvertTo-Hashtable $item })
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) { $ht[$prop.Name] = ConvertTo-Hashtable $prop.Value }
        return $ht
    }
    return $InputObject
}

function Merge-Hashtable {
    param([hashtable]$Base, [hashtable]$Override)

    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    if ($Override) {
        foreach ($key in $Override.Keys) {
            if ($result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
                $result[$key] = Merge-Hashtable $result[$key] $Override[$key]
            }
            else {
                $result[$key] = $Override[$key]
            }
        }
    }
    return $result
}

function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return @{} }
    return ConvertTo-Hashtable ($raw | ConvertFrom-Json)
}

function Save-JsonFile {
    param($InputObject, [string]$Path)
    # Ecriture atomique : fichier temporaire puis remplacement
    $tmp = "$Path.tmp"
    $json = $InputObject | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -Path $tmp -Destination $Path -Force
}

function ConvertTo-LocalDate {
    # Relit une date de l'etat : chaine ISO (PS 5.1) ou DateTime deja converti (PS 7)
    param($Value)
    if (-not $Value) { return $null }
    $date = if ($Value -is [datetime]) { $Value } else {
        [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    }
    if ($date.Kind -eq [DateTimeKind]::Utc) { return $date.ToLocalTime() }
    return [datetime]::SpecifyKind($date, [DateTimeKind]::Local)
}

function Format-StateDate {
    # Date ISO avec decalage horaire, insensible a la culture du serveur
    param($Value)
    if (-not $Value) { return $null }
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) { $Value = [datetime]::SpecifyKind($Value, [DateTimeKind]::Local) }
    return $Value.ToString('o')
}

################################################ Configuration et etat
function Import-Config {
    param([string]$Path, [hashtable]$Defaults)

    if (-not (Test-Path $Path)) {
        Save-JsonFile -InputObject $Defaults -Path $Path
        Write-ReportLog "Configuration de demo creee : $Path" 'WARN'
        Write-ReportLog 'Completez-la (client, client_shortname...) puis relancez le script.' 'WARN'
        return $null
    }

    try {
        $raw = Read-JsonFile $Path
    }
    catch {
        Write-ReportLog "Le fichier $Path est invalide, corrigez le JSON : $($_.Exception.Message)" 'ERROR'
        return $null
    }

    # Cles des versions precedentes du script
    if ($raw.ContainsKey('kumaUrl') -and -not $raw.ContainsKey('kuma')) { $raw.kuma = @{ url = $raw.kumaUrl } }
    if ($raw.ContainsKey('n8nWebhookUrl') -and -not $raw.ContainsKey('n8n')) { $raw.n8n = @{ webhookUrl = $raw.n8nWebhookUrl } }

    $config = Merge-Hashtable $Defaults $raw

    $errors = @()
    if (-not $config.client -or $config.client -eq $Defaults.client) { $errors += "'client' n'est pas renseigne" }
    if (-not $config.client_shortname -or $config.client_shortname -eq $Defaults.client_shortname) { $errors += "'client_shortname' n'est pas renseigne" }
    if (-not $config.kuma.url) { $errors += "'kuma.url' est vide" }
    if (-not $config.n8n.webhookUrl) { $errors += "'n8n.webhookUrl' est vide" }
    if (-not ($config.evaluation.toleranceFactor -gt 0)) { $errors += "'evaluation.toleranceFactor' doit etre > 0" }
    if (-not ($config.evaluation.defaultGapDays -gt 0)) { $errors += "'evaluation.defaultGapDays' doit etre > 0" }
    if (-not ($config.maxLookbackDays -gt 0)) { $errors += "'maxLookbackDays' doit etre > 0" }
    if (-not ($config.forgetAfterDays -ge $config.maxLookbackDays)) { $errors += "'forgetAfterDays' doit etre >= maxLookbackDays" }
    foreach ($pattern in @($config.exclude)) {
        if (-not $pattern) { continue }
        try { [void][regex]::new($pattern) } catch { $errors += "regex invalide dans 'exclude' : $pattern" }
    }

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Write-ReportLog "Configuration ($Path) : $e" 'ERROR' }
        return $null
    }
    return $config
}

function Import-State {
    param([string]$Path, [hashtable]$Config, [bool]$ReadOnly)

    if (Test-Path $Path) {
        $state = Read-JsonFile $Path
    }
    else {
        $state = @{}
        # Migration : les anciennes versions stockaient les tokens dans config.json (cle "backups")
        if ($Config.backups -is [hashtable] -and $Config.backups.Count -gt 0) {
            $state.tokens = $Config.backups
            Write-ReportLog "Tokens repris depuis la config ($($Config.backups.Count) type(s))"
            if (-not $ReadOnly) { Save-JsonFile -InputObject $state -Path $Path }
        }
    }
    if ($state.tokens -isnot [hashtable]) { $state.tokens = @{} }
    if ($state.records -isnot [hashtable]) { $state.records = @{} }
    return $state
}

function Get-StateRecords {
    param([hashtable]$State)

    $records = @{}
    foreach ($key in $State.records.Keys) {
        $r = $State.records[$key]
        $records[$key] = @{
            Name        = $r.name
            Type        = $r.type
            Source      = $r.source
            Jobs        = if ($r.jobs -is [hashtable]) { $r.jobs } else { @{} }
            LastSeen    = ConvertTo-LocalDate $r.lastSeen
            LastRun     = ConvertTo-LocalDate $r.lastRun
            LastResult  = $r.lastResult
            LastSuccess = ConvertTo-LocalDate $r.lastSuccess
            WarnStreak  = [int]$r.warnStreak
        }
    }
    return $records
}

function Set-StateRecords {
    param([hashtable]$State, [hashtable]$Records)

    $out = @{}
    foreach ($key in $Records.Keys) {
        $r = $Records[$key]
        $out[$key] = @{
            name        = $r.Name
            type        = $r.Type
            source      = $r.Source
            jobs        = $r.Jobs
            lastSeen    = Format-StateDate $r.LastSeen
            lastRun     = Format-StateDate $r.LastRun
            lastResult  = $r.LastResult
            lastSuccess = Format-StateDate $r.LastSuccess
            warnStreak  = $r.WarnStreak
        }
    }
    $State.records = $out
}

################################################ Veeam
function Import-VeeamPowerShell {
    if (Get-Command Get-VBRJob -ErrorAction SilentlyContinue) { return $true }
    try {
        # v11 et v12 : module PowerShell
        Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue
        return $true
    }
    catch { Write-ReportLog "Module Veeam.Backup.PowerShell indisponible : $($_.Exception.Message)" 'DEBUG' }
    try {
        # Versions anterieures : snap-in
        Add-PSSnapin VeeamPSSnapIn
        return $true
    }
    catch { Write-ReportLog "Snap-in VeeamPSSnapIn indisponible : $($_.Exception.Message)" 'DEBUG' }
    return $false
}

function Get-JobIndex {
    # Charge les jobs une seule fois : Get-VBRJob est lent sur les gros serveurs
    $byId = @{}
    $byName = @{}
    foreach ($job in @(Get-VBRJob -WarningAction SilentlyContinue)) {
        $byId[[string]$job.Id] = $job
        $byName[$job.Name] = $job
    }
    return @{ ById = $byId; ByName = $byName }
}

function Resolve-RootJob {
    param($Job, [hashtable]$Index)

    # Remonte les chaines "apres le job X" pour trouver le job qui porte le planning
    $visited = @{}
    while ($Job) {
        $visited[[string]$Job.Id] = $true
        $after = $Job.ScheduleOptions.OptionsScheduleAfterJob
        if (-not ($after -and $after.IsEnabled)) { return $Job }
        $parentId = [string]$Job.PreviousJobIdInScheduleChain
        if ($visited.ContainsKey($parentId) -or -not $Index.ById.ContainsKey($parentId)) { return $Job }
        $Job = $Index.ById[$parentId]
    }
    return $Job
}

function Resolve-SessionJob {
    param($Session, [hashtable]$Index)

    # Backup Copy : OrigJobName est de la forme "Copie\Source", le planning est celui du dernier segment
    $name = ([string]$Session.OrigJobName -split '\\')[-1]
    if ($name -and $Index.ByName.ContainsKey($name)) { return $Index.ByName[$name] }
    $id = [string]$Session.JobId
    if ($Index.ById.ContainsKey($id)) { return $Index.ById[$id] }
    if ($Session.JobName -and $Index.ByName.ContainsKey($Session.JobName)) { return $Index.ByName[$Session.JobName] }
    return $null
}

function Get-ScheduleGapDays {
    # Plus long intervalle entre deux executions planifiees, en jours. $null si illisible.
    param($Job)

    $schedule = $Job.ScheduleOptions
    if (-not $schedule) { return $null }

    if ($schedule.OptionsDaily -and $schedule.OptionsDaily.Enabled) {
        $days = @($schedule.OptionsDaily.DaysSrv | ForEach-Object { [int][DayOfWeek]"$_" } | Sort-Object -Unique)
        if ($days.Count -eq 0) { return 1 }
        $maxGap = 0
        for ($i = 0; $i -lt $days.Count; $i++) {
            $next = if ($i -eq $days.Count - 1) { $days[0] + 7 } else { $days[$i + 1] }
            $maxGap = [math]::Max($maxGap, $next - $days[$i])
        }
        return $maxGap
    }

    if ($schedule.OptionsPeriodically -and $schedule.OptionsPeriodically.Enabled) {
        $periodic = $schedule.OptionsPeriodically
        if ($periodic.PSObject.Properties['RepeatEvery'] -and $periodic.RepeatEvery -gt 0) {
            return [math]::Round($periodic.RepeatEvery / 24, 3)   # heures
        }
        if ($periodic.PSObject.Properties['FullPeriod'] -and $periodic.FullPeriod -gt 0) {
            return [math]::Round($periodic.FullPeriod / 1440, 3)  # minutes
        }
        return $null
    }

    if ($schedule.OptionsMonthly -and $schedule.OptionsMonthly.Enabled) { return 31 }

    return $null
}

function Get-JobGapDays {
    param($Job, [string]$JobName, [hashtable]$Config, [hashtable]$Index, [hashtable]$Cache)

    $cacheKey = if ($Job) { [string]$Job.Id } else { "name:$JobName" }
    if ($Cache.ContainsKey($cacheKey)) { return $Cache[$cacheKey] }

    $root = if ($Job) { Resolve-RootJob -Job $Job -Index $Index } else { $null }
    $gap = $null
    foreach ($name in @($JobName, $Job.Name, $root.Name)) {
        if ($name -and $Config.gapOverrides.ContainsKey($name)) { $gap = [double]$Config.gapOverrides[$name]; break }
    }
    if ($null -eq $gap -and $root) { $gap = Get-ScheduleGapDays -Job $root }
    if (-not ($gap -gt 0)) { $gap = [double]$Config.evaluation.defaultGapDays }

    $Cache[$cacheKey] = $gap
    return $gap
}

function Get-RecordGap {
    # Recalculee a chaque passage : un changement de planning ou de gapOverrides s'applique
    # aussi aux elements qui n'ont pas tourne depuis
    param([hashtable]$Record, [hashtable]$Config, [hashtable]$Index, [hashtable]$Cache)

    $gap = 0
    foreach ($jobName in $Record.Jobs.Keys) {
        $resolvedName = [string]$Record.Jobs[$jobName]
        $job = if ($resolvedName -and $Index.ByName.ContainsKey($resolvedName)) { $Index.ByName[$resolvedName] } else { $null }
        $gap = [math]::Max($gap, (Get-JobGapDays -Job $job -JobName $jobName -Config $Config -Index $Index -Cache $Cache))
    }
    if (-not ($gap -gt 0)) { $gap = [double]$Config.evaluation.defaultGapDays }
    return $gap
}

function Get-AnalysisStart {
    param($LastRunTime, [datetime]$Now, [double]$MaxDays)

    $oldest = $Now.AddDays(-$MaxDays)
    if (-not $LastRunTime) { return $oldest }
    # Marge d'une heure : les sessions deja traitees sont ignorees par Update-Record
    $start = $LastRunTime.AddHours(-1)
    if ($start -lt $oldest) { return $oldest }
    return $start
}

################################################ Collecte
function Get-TypeMap {
    # JobType Veeam -> source, libelle du type, granularite
    param([hashtable]$Config)

    $map = @{}
    foreach ($sourceName in $Config.sources.Keys) {
        $source = $Config.sources[$sourceName]
        if (-not $source.enabled) { continue }
        foreach ($jobType in $source.jobTypes.Keys) {
            $label = $source.jobTypes[$jobType]
            if (-not $label) { continue }   # libelle vide = type desactive
            $map[$jobType] = @{
                Source    = $sourceName
                Label     = $label
                PerObject = ($source.granularity -eq 'object')
            }
        }
    }
    return $map
}

function Update-Record {
    # A appeler dans l'ordre chronologique des sessions (compteur de warnings)
    param(
        [hashtable]$Records, [string]$Name, [hashtable]$Map, [string]$JobName,
        [string]$ResolvedJobName, [datetime]$End, [string]$Result, [bool]$WarningIsSuccess
    )

    $key = "$($Map.Label)|$Name"
    $record = $Records[$key]
    if (-not $record) {
        $record = @{
            Name = $Name; Type = $Map.Label; Source = $Map.Source; Jobs = @{}
            LastSeen = $null; LastRun = $null; LastResult = $null; LastSuccess = $null; WarnStreak = 0
        }
        $Records[$key] = $record
    }
    # Element present dans plusieurs jobs : la periodicite la plus large sera retenue
    $record.Jobs[$JobName] = $ResolvedJobName
    if ($null -eq $record.LastSeen -or $End -gt $record.LastSeen) { $record.LastSeen = $End }

    if ($ValidResults -notcontains $Result) { return }               # en cours, en attente...
    if ($null -ne $record.LastRun -and $End -le $record.LastRun) { return }  # deja traitee

    $record.LastRun = $End
    $record.LastResult = $Result
    if ($Result -eq 'Warning') { $record.WarnStreak++ } else { $record.WarnStreak = 0 }
    if (($Result -eq 'Success') -or ($WarningIsSuccess -and $Result -eq 'Warning')) {
        $record.LastSuccess = $End
    }
}

function Test-Excluded {
    param([string]$Name, [hashtable]$Config)
    foreach ($pattern in @($Config.exclude)) {
        if ($pattern -and $Name -match $pattern) { return $true }
    }
    return $false
}

function Update-BackupRecords {
    # Applique aux elements connus les sessions terminees depuis $Since
    param([hashtable]$Records, [hashtable]$Config, [hashtable]$Index, [hashtable]$TypeMap, [datetime]$Since)

    $sessionStats = @{}
    $warningIsSuccess = [bool]$Config.evaluation.warningIsSuccess

    # Les sessions en cours ont un EndTime en 1900 et sont donc exclues ici.
    # Ordre chronologique obligatoire pour le compteur de warnings consecutifs.
    Write-Step "Lecture des sessions Veeam terminees depuis $($Since.ToString('yyyy-MM-dd HH:mm')) (peut etre long)..."
    $sessions = @(Get-VBRBackupSession | Where-Object { $_.EndTime -ge $Since } | Sort-Object EndTime)
    Write-Step "$($sessions.Count) session(s) a analyser"

    $done = 0
    foreach ($session in $sessions) {
        $done++
        if ($done % 50 -eq 0) { Write-Step "Analyse des sessions : $done / $($sessions.Count)" }
        $jobType = [string]$session.JobType
        $sessionStats[$jobType] = 1 + [int]$sessionStats[$jobType]
        $map = $TypeMap[$jobType]
        if (-not $map) { continue }

        try {
            $job = Resolve-SessionJob -Session $session -Index $Index
            if (-not $job) { Write-ReportLog "Job introuvable pour '$($session.OrigJobName)', periodicite par defaut" 'DEBUG' }

            $common = @{
                Records = $Records; Map = $map; JobName = $session.JobName
                ResolvedJobName = $(if ($job) { $job.Name } else { '' })
                End = $session.EndTime; WarningIsSuccess = $warningIsSuccess
            }
            if ($map.PerObject) {
                # Les elements exclus sont suivis aussi : leur etat est a jour s'ils sont reactives
                foreach ($task in @($session.GetTaskSessions())) {
                    Update-Record @common -Name $task.Name -Result ([string]$task.Status)
                }
            }
            else {
                Update-Record @common -Name $session.JobName -Result ([string]$session.Result)
            }
        }
        catch {
            Write-ReportLog "Session '$($session.Name)' ignoree : $($_.Exception.Message)" 'WARN'
        }
    }

    return $sessionStats
}

function Remove-StaleRecords {
    param([hashtable]$Records, [datetime]$Now, [double]$ForgetAfterDays)

    $limit = $Now.AddDays(-$ForgetAfterDays)
    foreach ($key in @($Records.Keys)) {
        $lastSeen = $Records[$key].LastSeen
        if (-not $lastSeen -or $lastSeen -lt $limit) {
            Write-ReportLog "Oubli de $key : aucune session depuis plus de $ForgetAfterDays jour(s)"
            $Records.Remove($key)
        }
    }
}

################################################ Evaluation
function Get-RecordStatus {
    param([hashtable]$Record, [double]$Gap, [hashtable]$Evaluation, [datetime]$Now)

    $toleranceHours = [math]::Round($Gap * 24 * $Evaluation.toleranceFactor, 1)
    $maxWarnings = [int]$Evaluation.maxConsecutiveWarnings
    $ageHours = $null
    if ($Record.LastSuccess) { $ageHours = [math]::Floor(($Now - $Record.LastSuccess).TotalHours) }

    if ($Evaluation.failedIsDown -and $Record.LastResult -eq 'Failed') {
        $status = 'down'; $reason = 'Echec'
    }
    elseif ($maxWarnings -gt 0 -and $Record.WarnStreak -ge $maxWarnings) {
        $status = 'down'; $reason = "$($Record.WarnStreak) warnings consecutifs"
    }
    elseif ($null -eq $ageHours) {
        $status = 'down'; $reason = 'Aucun succes connu'
    }
    elseif ($ageHours -ge $toleranceHours) {
        $status = 'down'; $reason = "Perime (${ageHours}h, tolerance ${toleranceHours}h)"
    }
    else {
        $status = 'up'; $reason = 'OK'
    }

    $lastSuccess = if ($Record.LastSuccess) { $Record.LastSuccess.ToString('yyyy-MM-dd HH:mm') } else { 'jamais' }
    $message = '{0} - dernier succes {1} - dernier resultat {2}' -f $reason, $lastSuccess, $Record.LastResult

    return @{ Status = $status; Reason = $reason; AgeHours = $ageHours; ToleranceHours = $toleranceHours; Message = $message }
}

################################################ Exclusions
function Set-Exclusion {
    # Modifie la liste "exclude" de config.json (fichier brut, sans les valeurs par defaut)
    param([string]$ConfigFile, [string[]]$Add, [string[]]$Remove)

    $raw = Read-JsonFile $ConfigFile
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @($raw.exclude)) { if ($p) { [void]$list.Add([string]$p) } }

    foreach ($name in @($Add | Where-Object { $_ })) {
        $pattern = '^' + [regex]::Escape($name) + '$'
        if ($list -contains $pattern) { Write-ReportLog "$name est deja exclu"; continue }
        [void]$list.Add($pattern)
        Write-ReportLog "Exclusion ajoutee : $name" 'WARN'
    }
    foreach ($name in @($Remove | Where-Object { $_ })) {
        $pattern = '^' + [regex]::Escape($name) + '$'
        if ($list -contains $pattern) {
            $list.Remove($pattern)
            Write-ReportLog "Exclusion retiree : $name" 'WARN'
        }
        else {
            Write-ReportLog "$name n'etait pas exclu par -Exclude" 'WARN'
        }
        foreach ($other in $list) {
            if ($name -match $other) { Write-ReportLog "$name reste exclu par le motif '$other' de config.json" 'WARN' }
        }
    }

    $raw.exclude = @($list)
    Save-JsonFile -InputObject $raw -Path $ConfigFile
    $current = if ($list.Count) { $list -join ', ' } else { '(aucune)' }
    Write-ReportLog "Exclusions actuelles : $current"
}

################################################ Publication
function Reset-MonitorToken {
    # Retire les tokens correspondant aux motifs "Type/Nom" ; renvoie le nombre retire
    param([hashtable]$State, [string[]]$Patterns, [bool]$DryRun)

    $removed = 0
    foreach ($type in @($State.tokens.Keys)) {
        if ($State.tokens[$type] -isnot [hashtable]) { continue }
        foreach ($name in @($State.tokens[$type].Keys)) {
            $id = "$type/$name"
            $match = @($Patterns | Where-Object { $id -eq $_ -or $id -like $_ }).Count -gt 0
            if (-not $match) { continue }
            $removed++
            if ($DryRun) { Write-ReportLog "[simulation] Token oublie : $id"; continue }
            $State.tokens[$type].Remove($name)
            Write-ReportLog "Token oublie, moniteur a recreer : $id" 'WARN'
        }
    }
    if ($removed -eq 0) { Write-ReportLog "ResetMonitor : aucun token ne correspond a '$($Patterns -join "', '")'" 'WARN' }
    return $removed
}

function Get-MonitorToken {
    param([hashtable]$Record, [double]$Gap, [hashtable]$Config, [hashtable]$State, [string]$StatePath, [bool]$DryRun)

    $tokens = $State.tokens
    if ($tokens[$Record.Type] -isnot [hashtable]) { $tokens[$Record.Type] = @{} }
    $token = $tokens[$Record.Type][$Record.Name]
    if ($token) { return $token }
    if ($DryRun) { return $null }

    Write-ReportLog "Creation du moniteur via n8n : $($Record.Type) / $($Record.Name)"
    $body = @{
        customer_name      = $Config.client
        customer_shortname = $Config.client_shortname
        name               = $Record.Name
        type               = $Record.Type
        base               = 'Backups'
        gap                = $Gap
    } | ConvertTo-Json -Depth 5

    try {
        # Corps en octets UTF-8 : PowerShell 5.1 encode mal les chaines accentuees
        $response = Invoke-RestMethod -Method Post -Uri $Config.n8n.webhookUrl `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -ContentType 'application/json; charset=utf-8' `
            -TimeoutSec $Config.n8n.timeoutSec -UseBasicParsing
    }
    catch {
        Write-ReportLog "Appel n8n en echec pour $($Record.Name) : $($_.Exception.Message)" 'ERROR'
        return $null
    }

    $token = (@($response)[0]).push_token
    if (-not $token) {
        Write-ReportLog "Aucun push_token recu de n8n pour $($Record.Name)" 'ERROR'
        return $null
    }

    # Sauvegarde immediate : evite de recreer le moniteur si le script s'arrete ensuite
    $tokens[$Record.Type][$Record.Name] = $token
    Save-JsonFile -InputObject $State -Path $StatePath
    return $token
}

function Send-KumaPush {
    param([hashtable]$Config, [string]$Token, [string]$Status, [string]$Message, $Ping)

    $base = [string]$Config.kuma.url
    if (-not $base.EndsWith('/')) { $base += '/' }
    $url = '{0}{1}?status={2}&msg={3}' -f $base, $Token, $Status, [uri]::EscapeDataString($Message)
    if ($null -ne $Ping) { $url += "&ping=$Ping" }

    $attempts = 1 + [int]$Config.kuma.retries
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec $Config.kuma.timeoutSec `
                -UseBasicParsing -UserAgent 'QDC-VeeamReport'
            if ($response -and $response.PSObject.Properties['ok'] -and -not $response.ok) {
                Write-ReportLog "Kuma a refuse le push ($Token) : $($response.msg)" 'WARN'
                return 'refused'
            }
            return 'ok'
        }
        catch {
            # Reponse HTTP 4xx : Kuma est joignable mais refuse (moniteur supprime ou en pause -> 404)
            $httpCode = 0
            if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
            if ($httpCode -ge 400 -and $httpCode -lt 500) {
                Write-ReportLog "Kuma a refuse le push ($Token) : HTTP $httpCode, moniteur supprime ou en pause ? (voir -ResetMonitor)" 'WARN'
                return 'refused'
            }
            # Pas de reponse, timeout ou 5xx (proxy devant un Kuma arrete) : on reessaie
            Write-ReportLog "Push Kuma en echec (tentative $i/$attempts) : $($_.Exception.Message)" 'WARN'
            if ($i -lt $attempts) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    return 'unreachable'
}

################################################ Diagnostic
function Show-Diagnostic {
    param([hashtable]$Index, [hashtable]$TypeMap, [hashtable]$SessionStats, [hashtable]$Records,
          [System.Collections.IEnumerable]$Rows, [datetime]$Since)

    $module = Get-Module Veeam.Backup.PowerShell
    Write-Host ''
    Write-Host '=== Environnement' -ForegroundColor Cyan
    Write-Host "PowerShell        : $($PSVersionTable.PSVersion)"
    Write-Host "Module Veeam      : $(if ($module) { $module.Version } else { 'snap-in / inconnu' })"
    Write-Host "Sessions depuis   : $($Since.ToString('yyyy-MM-dd HH:mm'))"

    Write-Host ''
    Write-Host '=== Types de jobs (Get-VBRJob)' -ForegroundColor Cyan
    $Index.ById.Values | Group-Object { [string]$_.JobType } | Sort-Object Name | ForEach-Object {
        $mapped = if ($TypeMap.ContainsKey($_.Name)) { "-> $($TypeMap[$_.Name].Source) / $($TypeMap[$_.Name].Label)" } else { '(ignore)' }
        Write-Host ('{0,-28} {1,4}  {2}' -f $_.Name, $_.Count, $mapped)
    }

    Write-Host ''
    Write-Host '=== Types de sessions sur la periode' -ForegroundColor Cyan
    foreach ($jobType in ($SessionStats.Keys | Sort-Object)) {
        $mapped = if ($TypeMap.ContainsKey($jobType)) { "-> $($TypeMap[$jobType].Source) / $($TypeMap[$jobType].Label)" } else { '(ignore)' }
        Write-Host ('{0,-28} {1,4}  {2}' -f $jobType, $SessionStats[$jobType], $mapped)
    }

    # Jobs surveilles sans aucune session connue : jamais executes, desactives, ou sessions
    # invisibles pour Get-VBRBackupSession (a signaler si le job a pourtant tourne)
    $seenJobs = @{}
    foreach ($r in $Records.Values) { foreach ($j in $r.Jobs.Keys) { $seenJobs[$j] = $true } }
    $silent = @($Index.ById.Values | Where-Object { $TypeMap.ContainsKey([string]$_.JobType) -and -not $seenJobs.ContainsKey($_.Name) })
    if ($silent.Count) {
        Write-Host ''
        Write-Host '=== Jobs surveilles sans session connue (pas encore de moniteur)' -ForegroundColor Yellow
        foreach ($job in ($silent | Sort-Object Name)) {
            Write-Host ('{0,-40} {1,-16} planifie : {2}' -f $job.Name, $job.JobType, $(if ($job.IsScheduleEnabled) { 'oui' } else { 'non' })) -ForegroundColor Yellow
        }
        Write-Host "Si l'un de ces jobs a deja tourne, ses sessions ne sont pas lues : envoyez cette sortie." -ForegroundColor Yellow
    }

    # Jobs File Backup non vus par Get-VBRJob : leur periodicite retombe sur la valeur par defaut
    foreach ($cmd in @('Get-VBRUnstructuredBackupJob', 'Get-VBRNASBackupJob')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { continue }
        try {
            $missing = @(& $cmd -WarningAction SilentlyContinue | Where-Object { -not $Index.ById.ContainsKey([string]$_.Id) })
            foreach ($job in $missing) {
                Write-Host "Job '$($job.Name)' absent de Get-VBRJob : periodicite par defaut, ajustez via gapOverrides si besoin" -ForegroundColor Yellow
            }
        }
        catch { Write-Host "$cmd en echec : $($_.Exception.Message)" -ForegroundColor Yellow }
        break
    }

    Write-Host ''
    Write-Host '=== Evaluation' -ForegroundColor Cyan
    $Rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
}

################################################ Programme principal
function Invoke-VeeamReport {
    param([string]$ConfigPath, [string]$StatePath, [bool]$DryRun, [bool]$Diagnose, [string[]]$ResetMonitor,
          [string[]]$Exclude, [string[]]$Include)

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'config.json' }
    $configFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    $configDir = Split-Path $configFile -Parent
    $stateFile = if ($StatePath) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath) } else { Join-Path $configDir 'veeam_state.json' }
    $isDryRun = [bool]($DryRun -or $Diagnose)

    $config = Import-Config -Path $configFile -Defaults $DefaultConfig
    if (-not $config) { return 1 }

    if ($config.logFile) {
        $logPath = if ([System.IO.Path]::IsPathRooted($config.logFile)) { $config.logFile } else { Join-Path $configDir $config.logFile }
        Initialize-Log -Path $logPath
    }
    # Gestion des exclusions : modifie la config et quitte, sans interroger Veeam
    if ($Exclude -or $Include) {
        Set-Exclusion -ConfigFile $configFile -Add $Exclude -Remove $Include
        return 0
    }

    Write-ReportLog "Demarrage - client $($config.client)$(if ($isDryRun) { ' (simulation)' })"

    # Un seul rapport a la fois (planification qui se chevauche)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\QDC_VeeamReport')
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            Write-ReportLog 'Une autre execution est en cours, abandon.' 'WARN'
            return 3
        }

        try {
            Write-Step 'Chargement du PowerShell Veeam...'
            if (-not (Import-VeeamPowerShell)) {
                Write-ReportLog 'Impossible de charger le PowerShell Veeam (module ou snap-in).' 'ERROR'
                return 2
            }

            $state = Import-State -Path $stateFile -Config $config -ReadOnly $isDryRun
            if ($ResetMonitor) { [void](Reset-MonitorToken -State $state -Patterns $ResetMonitor -DryRun $isDryRun) }
            $knownRecords = Get-StateRecords -State $state
            Write-Step 'Lecture des jobs Veeam...'
            $index = Get-JobIndex
            Write-Step "$($index.ById.Count) job(s) trouve(s)"
            $typeMap = Get-TypeMap -Config $config
            $gapCache = @{}
            $now = Get-Date

            # Le diagnostic relit toute la fenetre pour montrer tous les types de sessions
            $lastRunTime = if ($Diagnose) { $null } else { ConvertTo-LocalDate $state.lastRunTime }
            $since = Get-AnalysisStart -LastRunTime $lastRunTime -Now $now -MaxDays $config.maxLookbackDays
            $sessionStats = Update-BackupRecords -Records $knownRecords -Config $config -Index $index -TypeMap $typeMap -Since $since
            Remove-StaleRecords -Records $knownRecords -Now $now -ForgetAfterDays $config.forgetAfterDays

            # Etat enregistre avant les envois : un echec reseau ne fait pas relire les sessions
            if (-not $isDryRun) {
                Set-StateRecords -State $state -Records $knownRecords
                $state.lastRunTime = Format-StateDate $now
                Save-JsonFile -InputObject $state -Path $stateFile
            }

            # Elements des sources desactivees ou exclus : conserves dans l'etat mais pas publies
            $enabledTypes = @{}
            foreach ($map in $typeMap.Values) { $enabledTypes[$map.Label] = $true }
            $records = @($knownRecords.Values |
                Where-Object { $enabledTypes.ContainsKey($_.Type) -and -not (Test-Excluded -Name $_.Name -Config $config) } |
                Sort-Object { $_.Source }, { $_.Type }, { $_.Name })
            Write-Step "$($records.Count) element(s) a publier$(if (-not $isDryRun) { ' vers Kuma' })"

            $rows = @()
            $up = 0; $down = 0; $errors = 0
            $kumaFailures = 0; $skipped = 0
            $maxKumaFailures = [int]$config.kuma.maxConsecutiveFailures
            foreach ($record in $records) {
                $gap = Get-RecordGap -Record $record -Config $config -Index $index -Cache $gapCache
                $evaluation = Get-RecordStatus -Record $record -Gap $gap -Evaluation $config.evaluation -Now $now
                if ($evaluation.Status -eq 'up') { $up++ } else { $down++ }

                # Dates courtes et colonnes compactes : le tableau doit tenir dans une console standard
                $rows += [pscustomobject]@{
                    Type       = $record.Type
                    Nom        = $record.Name
                    Gap        = $gap
                    DernierRun = $(if ($record.LastRun) { $record.LastRun.ToString('yyyy-MM-dd HH:mm') })
                    Resultat   = $record.LastResult
                    Warn       = $record.WarnStreak
                    DernierOK  = $(if ($record.LastSuccess) { $record.LastSuccess.ToString('yyyy-MM-dd HH:mm') })
                    Statut     = $evaluation.Status
                    Raison     = $evaluation.Reason
                    Moniteur   = $(if ($state.tokens[$record.Type] -is [hashtable] -and $state.tokens[$record.Type][$record.Name]) { 'oui' } else { 'a creer' })
                }

                $logLine = "$($record.Type) / $($record.Name) : $($evaluation.Status) - $($evaluation.Message)"
                if ($isDryRun) { Write-ReportLog "[simulation] $logLine" 'DEBUG'; continue }

                # Kuma injoignable : inutile d'attendre les timeouts ni de creer des moniteurs
                if ($maxKumaFailures -gt 0 -and $kumaFailures -ge $maxKumaFailures) { $skipped++; continue }

                $token = Get-MonitorToken -Record $record -Gap $gap -Config $config -State $state -StatePath $stateFile -DryRun $isDryRun
                if (-not $token) { $errors++; continue }

                $result = Send-KumaPush -Config $config -Token $token -Status $evaluation.Status -Message $evaluation.Message -Ping $evaluation.AgeHours
                if ($result -eq 'ok') {
                    $kumaFailures = 0
                    Write-ReportLog $logLine
                    continue
                }
                Write-ReportLog "Push non transmis - $logLine" 'ERROR'
                $errors++
                if ($result -eq 'refused') { $kumaFailures = 0 }   # Kuma repond : il est joignable
                if ($result -eq 'unreachable') {
                    $kumaFailures++
                    if ($maxKumaFailures -gt 0 -and $kumaFailures -ge $maxKumaFailures) {
                        Write-ReportLog "Kuma injoignable ($kumaFailures echecs successifs) : envois restants abandonnes" 'ERROR'
                    }
                }
            }
            if ($skipped -gt 0) {
                Write-ReportLog "$skipped element(s) non envoye(s) car Kuma est injoignable" 'ERROR'
                $errors += $skipped
            }

            if ($Diagnose) {
                Show-Diagnostic -Index $index -TypeMap $typeMap -SessionStats $sessionStats -Records $knownRecords -Rows $rows -Since $since
            }
            elseif ($isDryRun) {
                $rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
            }

            Write-Step "Termine : $up up, $down down, $errors erreur(s)"
            if ($errors -gt 0) { return 4 }
            return 0
        }
        finally {
            if ($acquired) { $mutex.ReleaseMutex() }
        }
    }
    finally {
        $mutex.Dispose()
    }
}

try {
    $exitCode = Invoke-VeeamReport -ConfigPath $ConfigPath -StatePath $StatePath -DryRun $DryRun -Diagnose $Diagnose -ResetMonitor $ResetMonitor -Exclude $Exclude -Include $Include
}
catch {
    Write-ReportLog "Erreur inattendue : $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))" 'ERROR'
    $exitCode = 5
}
exit $exitCode
