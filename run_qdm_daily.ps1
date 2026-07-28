<#
.SYNOPSIS
  QDM -> MT5 data sync, QuantDataManager side. Part of qdm-mt5-autosync.
  Pure runner - all settings live in config.json (same folder as this script).

  Multi-source: symbols are grouped by QDM data source (dukascopy, darwinex,
  crypto, yahoo...). Each source can carry its own export timezone. Exports
  land in per-source subfolders (M1\<source>\, TICK\<source>\) and the
  QdmImporter service names custom symbols <SYMBOL>_<source> accordingly
  (EURUSD_dukascopy, WS30_darwinex).

  Pipeline:
    0. Validate config symbols against QDM's registry; auto-register missing
       symbols under their configured source
    1. -data action=update              (incremental download, all registered)
    2. Per source: M1 export (single session)
    3. Per source: TICK export in small sequential batches

  Completion detection per phase (qdmcli -data jobs are ASYNC; -exit in the
  command file kills them instantly, so phases run WITHOUT -exit):
    1. qdmcli exits on its own (it does, once all jobs finish)
    2. completion markers in the phase log
    3. FALLBACK: phase log stops growing for a long window -> stop + WARNING
  The activity signal is the LOG FILE read through an open handle - never
  directory-listed CSV sizes, which NTFS updates lazily for open files.

.USAGE
  Daily run   :  powershell -ExecutionPolicy Bypass -File run_qdm_daily.ps1
  Full export :  ... run_qdm_daily.ps1 -Full
  Setup       :  ... run_qdm_daily.ps1 -Setup      (bulk-register config symbols)
  Cleanup     :  ... run_qdm_daily.ps1 -Cleanup    (delete '(n)' duplicate symbols)

.SCHEDULE (run once, elevated - adjust the script path):
  schtasks /Create /TN "QDM-MT5-DailySync" /TR "powershell -ExecutionPolicy Bypass -File D:\Trading\qdm-mt5-autosync\run_qdm_daily.ps1" /SC DAILY /ST 09:00 /RL HIGHEST /F
#>

param(
    [switch]$Full,
    [switch]$Setup,
    [switch]$Cleanup,
    [string]$ConfigPath = "",
    [string]$OnlySource = "",    # limit run to one source, e.g. -OnlySource darwinex
    [string]$OnlySymbols = ""    # limit run to specific symbols (csv), e.g. -OnlySymbols "XAUUSD,USDJPY"
)

$ErrorActionPreference = "Stop"

# ============================== LOAD CONFIG =================================

$WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($ConfigPath -eq "") { $ConfigPath = Join-Path $WorkDir "config.json" }

if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found at: $ConfigPath`nCopy config.example.json to config.json and edit it, then re-run."
    exit 1
}
try   { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
catch { Write-Error "config.json is not valid JSON: $($_.Exception.Message)"; exit 1 }

foreach ($key in @("QdmDir","WindowDays","FullFromDate")) {
    if (-not ($cfg.PSObject.Properties.Name -contains $key)) {
        Write-Error "config.json is missing required field: $key"; exit 1
    }
}
if (-not (Test-Path $cfg.QdmDir)) { Write-Error "config.json QdmDir does not exist: $($cfg.QdmDir)"; exit 1 }

$QdmDir     = $cfg.QdmDir
$QdmCli     = Join-Path $QdmDir "qdmcli.exe"
$LogDir     = Join-Path $WorkDir "logs"
if (-not (Test-Path $QdmCli)) { Write-Error "qdmcli.exe not found at: $QdmCli"; exit 1 }

function Get-CfgVal($name, $default) {
    if ($cfg.PSObject.Properties.Name -contains $name -and $null -ne $cfg.$name -and "$($cfg.$name)" -ne "") { return $cfg.$name }
    return $default
}
$Mt5Common      = Get-CfgVal "Mt5CommonOverride" (Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Files\QDM")
$WindowDays     = [int](Get-CfgVal "WindowDays" 7)
$FullFromDate   = [string]$cfg.FullFromDate
$TickBatchSize  = [int](Get-CfgVal "TickBatchSize" 3)
$MinFreeSpaceGB = [int](Get-CfgVal "MinFreeSpaceGB" 60)

# --- sources: name -> { Timezone, M1Symbols[], TickSymbols[] } --------------
$SourceList = @()   # array of PSCustomObject: Name, Timezone, M1, Tick
if ($cfg.PSObject.Properties.Name -contains "Sources") {
    foreach ($p in $cfg.Sources.PSObject.Properties) {
        if ($p.Name -like "_*") { continue }
        $s = $p.Value
        $SourceList += [pscustomobject]@{
            Name     = $p.Name
            Timezone = if ($s.PSObject.Properties.Name -contains "Timezone") { [string]$s.Timezone } else { "" }
            M1       = if ($s.PSObject.Properties.Name -contains "M1Symbols")   { @($s.M1Symbols) }   else { @() }
            Tick     = if ($s.PSObject.Properties.Name -contains "TickSymbols") { @($s.TickSymbols) } else { @() }
        }
    }
} elseif ($cfg.PSObject.Properties.Name -contains "M1Symbols") {
    # backward-compatible flat config
    $SourceList += [pscustomobject]@{
        Name     = [string](Get-CfgVal "DataSource" "dukascopy")
        Timezone = ""
        M1       = @($cfg.M1Symbols)
        Tick     = if ($cfg.PSObject.Properties.Name -contains "TickSymbols") { @($cfg.TickSymbols) } else { @() }
    }
}
if ($SourceList.Count -eq 0 -or (@($SourceList | ForEach-Object { $_.M1.Count + $_.Tick.Count }) | Measure-Object -Sum).Sum -eq 0) {
    Write-Error "config.json defines no symbols (Sources block empty)."; exit 1
}

# --- optional run scoping ---------------------------------------------------
if ($OnlySource -ne "") {
    $SourceList = @($SourceList | Where-Object { $_.Name -ieq $OnlySource })
    if ($SourceList.Count -eq 0) { Write-Error "-OnlySource '$OnlySource' matches no source in config.json."; exit 1 }
}
if ($OnlySymbols -ne "") {
    $wantOnly = @($OnlySymbols -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    foreach ($s in $SourceList) {
        $s.M1   = @($s.M1   | Where-Object { $wantOnly -contains $_ })
        $s.Tick = @($s.Tick | Where-Object { $wantOnly -contains $_ })
    }
    $SourceList = @($SourceList | Where-Object { $_.M1.Count + $_.Tick.Count -gt 0 })
    if ($SourceList.Count -eq 0) { Write-Error "-OnlySymbols '$OnlySymbols' matches no configured symbols."; exit 1 }
}

$wd = if ($cfg.PSObject.Properties.Name -contains "Watchdog") { $cfg.Watchdog } else { $null }
function Get-WdVal($name, $default) {
    if ($wd -and ($wd.PSObject.Properties.Name -contains $name)) { return [int]$wd.$name }
    return $default
}
$UpdateQuiesceSec = Get-WdVal "UpdateQuiesceSec" 900
$UpdateTimeoutMin = Get-WdVal "UpdateTimeoutMin" 720
$ExportQuiesceSec = Get-WdVal "ExportQuiesceSec" 600
$ExportTimeoutMin = Get-WdVal "ExportTimeoutMin" 480
$MinPhaseRunSec   = Get-WdVal "MinPhaseRunSec"   120

# ============================================================================

$outM1Root   = Join-Path $Mt5Common "M1"
$outTickRoot = Join-Path $Mt5Common "TICK"
$dirs = @($LogDir, $Mt5Common, $outM1Root, $outTickRoot, (Join-Path $Mt5Common "done"))
foreach ($s in $SourceList) {
    $dirs += (Join-Path $outM1Root $s.Name)
    $dirs += (Join-Path $outTickRoot $s.Name)
}
New-Item -ItemType Directory -Force -Path $dirs | Out-Null

$stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$cmdFile = Join-Path $WorkDir "qdm_commands.txt"

# --- run lock: two sync runs must NEVER overlap (the second would kill the
# first's qdmcli via Assert-QdmFree and both would then corrupt each other) --
$lockFile = Join-Path $WorkDir "run.lock"
if (Test-Path $lockFile) {
    $oldPid = [int]((Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1) -as [int])
    $alive  = if ($oldPid -gt 0) { Get-Process -Id $oldPid -ErrorAction SilentlyContinue } else { $null }
    if ($alive) {
        Write-Error "Another sync run is already active (pid $oldPid, lock: $lockFile). Let it finish or stop it first. Aborting."
        exit 1
    }
    Write-Warning "Removing stale lock left by dead pid $oldPid."
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
$PID | Set-Content -Path $lockFile
function Exit-Run { param([int]$Code = 0)
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    exit $Code
}
trap { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue; break }

# --- purge old archives from done\ (only relevant when the service's
# InpDonePolicy is "move"; full tick seeds can pile up hundreds of GB) -------
$DoneRetentionDays = [int](Get-CfgVal "DoneRetentionDays" 3)
$doneDir = Join-Path $Mt5Common "done"
if ($DoneRetentionDays -ge 0 -and (Test-Path $doneDir)) {
    $cutoff = (Get-Date).AddDays(-$DoneRetentionDays)
    $old = @(Get-ChildItem $doneDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($old.Count -gt 0) {
        $freedGB = [math]::Round((($old | Measure-Object Length -Sum).Sum) / 1GB, 1)
        $old | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Purged $($old.Count) archived file(s) older than $DoneRetentionDays day(s) from done\ (freed ~$freedGB GB)"
    }
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " CONFIG LOADED: $ConfigPath" -ForegroundColor Cyan
Write-Host " QDM dir        : $QdmDir" -ForegroundColor Cyan
Write-Host " MT5 Common\QDM : $Mt5Common" -ForegroundColor Cyan
foreach ($s in $SourceList) {
    $tz = if ($s.Timezone) { $s.Timezone } else { "native/UTC" }
    Write-Host " [$($s.Name)] tz=$tz | M1: $($s.M1.Count) | Tick: $($s.Tick.Count)" -ForegroundColor Cyan
    Write-Host "    M1  : $($s.M1 -join ', ')" -ForegroundColor Cyan
    if ($s.Tick.Count -gt 0) { Write-Host "    Tick: $($s.Tick -join ', ')" -ForegroundColor Cyan }
}
Write-Host " Window days: $WindowDays | Full-seed from: $(if ($FullFromDate) {$FullFromDate} else {'(all history)'}) | Tick batch: $TickBatchSize" -ForegroundColor Cyan
Write-Host "========================================================================`n" -ForegroundColor Cyan

# --- QDM is single-instance ------------------------------------------------
function Assert-QdmFree {
    $cli = Get-Process qdmcli -ErrorAction SilentlyContinue
    if ($cli) {
        Write-Warning "Stale qdmcli.exe instance(s) found (pid $($cli.Id -join ',')) - terminating."
        $cli | ForEach-Object { & taskkill /PID $_.Id /T /F 2>$null | Out-Null }
        Start-Sleep 3
    }
    $gui = Get-Process QuantDataManager, QDataManager -ErrorAction SilentlyContinue
    if ($gui) {
        Write-Error "QuantDataManager GUI is running - close it first (QDM is single-instance). Aborting."
        Exit-Run 1
    }
}
Assert-QdmFree

function Write-CmdFile { param([string[]]$Lines)
    $Lines | Set-Content -Path $cmdFile -Encoding ASCII
    Write-Host "=== qdmcli commands ==="; $Lines | Write-Host
}

function Invoke-QdmSync { param([string[]]$Lines)
    $log = Join-Path $LogDir "qdm_sync_$stamp.log"
    Write-CmdFile ($Lines + "-exit")
    $runArg = "file=" + ($cmdFile -replace '\\','/')
    cmd /c "`"$QdmCli`" -run $runArg > `"$log`" 2>&1"
    Write-Host "--- qdmcli output (last 40 lines) ---"
    Get-Content $log -Tail 40 | Write-Host
}

# --- open-handle file length: immune to NTFS lazy directory-size updates ----
function Get-LiveFileLength { param([string]$Path)
    if (-not (Test-Path $Path)) { return -1 }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $len = $fs.Length; $fs.Close()
        return $len
    } catch { return -1 }
}

# --- async phases -----------------------------------------------------------
function Invoke-QdmPhase {
    param(
        [string[]]$Lines,
        [scriptblock]$CompleteCheck,
        [int]$QuiesceSec, [int]$TimeoutMin, [string]$Phase
    )

    $log = Join-Path $LogDir "qdm_${Phase}_$stamp.log"
    Write-CmdFile $Lines
    $runArg = "file=" + ($cmdFile -replace '\\','/')
    $p = Start-Process -FilePath $QdmCli -ArgumentList "-run", $runArg `
         -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
         -PassThru -WindowStyle Hidden

    $started  = Get-Date
    $deadline = $started.AddMinutes($TimeoutMin)
    $minRunOk = $started.AddSeconds($MinPhaseRunSec)
    $lastLen  = -1; $stableSince = Get-Date
    $endReason = ""

    Write-Host "[$Phase] started (pid $($p.Id)). Watching for completion (fallback quiet window: $QuiesceSec s)..."
    while ($true) {
        Start-Sleep -Seconds 15

        if ($p.HasExited) { $endReason = "exit"; break }
        if ((Get-Date) -gt $deadline) {
            Write-Warning "[$Phase] absolute timeout ($TimeoutMin min) reached - forcing stop."
            $endReason = "timeout"; break
        }
        if (& $CompleteCheck $log) {
            Write-Host "[$Phase] completion markers found in log - 30 s grace, then stopping."
            Start-Sleep 30
            $endReason = "marker"; break
        }

        $len = Get-LiveFileLength $log
        if ($len -ne $lastLen) {
            $lastLen = $len; $stableSince = Get-Date
        } elseif ((Get-Date) -gt $minRunOk -and ((Get-Date) - $stableSince).TotalSeconds -ge $QuiesceSec) {
            Write-Warning "[$Phase] FALLBACK STOP: phase log frozen for $QuiesceSec s and no completion marker."
            Write-Warning "[$Phase] Data may be incomplete for this run - the next run's overlap will backfill."
            $endReason = "quiesce"; break
        }
    }
    if (-not $p.HasExited) { & taskkill /PID $p.Id /T /F 2>$null | Out-Null; Start-Sleep 3 }

    $confirmed = (& $CompleteCheck $log)
    switch ($endReason) {
        "exit"    { if ($confirmed) { Write-Host "[$Phase] finished cleanly (self-exit + markers confirmed)." }
                    else            { Write-Warning "[$Phase] process self-exited but completion markers are missing - check the log." } }
        "marker"  { Write-Host "[$Phase] finished (confirmed by log markers)." }
        default   { if ($confirmed) { Write-Host "[$Phase] markers confirm completion despite forced stop." }
                    else            { Write-Warning "[$Phase] ended by '$endReason' WITHOUT completion confirmation." } }
    }
    Write-Host "--- [$Phase] qdmcli output (last 10 lines) ---"
    if (Test-Path $log) { Get-Content $log -Tail 10 | Write-Host }
}

function New-ExportCheck { param([int]$Expected)
    return {
        param($log)
        if (-not (Test-Path $log)) { return $false }
        $done = (Select-String -Path $log -Pattern 'Completed, 100%' -AllMatches |
                 ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
        return ($done -ge $Expected)
    }.GetNewClosure()
}

function Get-QdmRegistrySymbols {
    $listLog = Join-Path $LogDir "registry_$stamp.log"
    ("-symbol action=list > " + ($listLog -replace '\\','/'), "-exit") | Set-Content -Path $cmdFile -Encoding ASCII
    cmd /c "`"$QdmCli`" -run file=$(($cmdFile -replace '\\','/')) > nul 2>&1"
    if (-not (Test-Path $listLog)) { return @() }
    return @(Get-Content $listLog |
             Where-Object { $_ -match '^[A-Za-z0-9]+,' -and $_ -notmatch '^Symbol,' } |
             ForEach-Object { ($_ -split ',')[0] } | Sort-Object -Unique)
}

# --- one-time bulk registration --------------------------------------------
if ($Setup) {
    $registry = Get-QdmRegistrySymbols
    $lines = @()
    foreach ($s in $SourceList) {
        $wanted  = @($s.M1) + @($s.Tick) | Sort-Object -Unique
        $missing = @($wanted | Where-Object { $registry -notcontains $_ })
        foreach ($b in $missing) { $lines += "-symbol action=add symbols=$b datasource=$($s.Name) datatype=TICK" }
    }
    if ($lines.Count -eq 0) { Write-Host "All config symbols already registered in QDM. Nothing to do."; Exit-Run 0 }
    $lines += "-symbol action=list > " + ((Join-Path $LogDir "symbols.log") -replace '\\','/')
    Invoke-QdmSync -Lines $lines
    Exit-Run 0
}

# --- remove duplicate '(n)' symbols ----------------------------------------
if ($Cleanup) {
    Invoke-QdmSync -Lines @("-symbol action=list > " + ((Join-Path $LogDir "symbols_before_cleanup.log") -replace '\\','/'))
    $dupes = Select-String -Path (Join-Path $LogDir "symbols_before_cleanup.log") -Pattern '([A-Z0-9]+\(\d+\))' -AllMatches |
             ForEach-Object { $_.Matches.Value } | Sort-Object -Unique
    if (-not $dupes -or $dupes.Count -eq 0) { Write-Host "No '(n)' duplicate symbols found."; Exit-Run 0 }
    Write-Host "Found duplicates:`n  $($dupes -join "`n  ")"
    $confirm = Read-Host "Delete these from QDM? (yes/no)"
    if ($confirm -eq "yes") {
        Invoke-QdmSync -Lines @("-symbol action=delete symbols=" + ($dupes -join ","))
        Write-Host "Duplicates deleted."
    }
    Exit-Run 0
}

# ============================ MAIN PIPELINE =================================

# STEP 0a - disk space guard
$driveLetter = $Mt5Common.Substring(0,1)
$freeGB = [math]::Round((Get-PSDrive $driveLetter).Free / 1GB, 1)
Write-Host "Free space on ${driveLetter}: $freeGB GB (minimum configured: $MinFreeSpaceGB GB)"
if ($freeGB -lt $MinFreeSpaceGB) {
    if ($Full) {
        Write-Error "Not enough free space on ${driveLetter}: for a -Full seed ($freeGB GB < $MinFreeSpaceGB GB)."
        Exit-Run 1
    }
    Write-Warning "Low disk space on ${driveLetter}: ($freeGB GB). Continuing with daily window."
}

# STEP 0b - validate/auto-register per source
$registry = Get-QdmRegistrySymbols
if ($registry.Count -eq 0) {
    Write-Warning "Could not read QDM symbol registry - proceeding with config lists as-is."
} else {
    foreach ($s in $SourceList) {
        $wanted  = @($s.M1) + @($s.Tick) | Sort-Object -Unique
        $missing = @($wanted | Where-Object { $registry -notcontains $_ })
        if ($missing.Count -gt 0) {
            Write-Host "[$($s.Name)] not in QDM registry: $($missing -join ', ') - auto-registering..."
            $lines = @()
            foreach ($b in $missing) { $lines += "-symbol action=add symbols=$b datasource=$($s.Name) datatype=TICK" }
            Invoke-QdmSync -Lines $lines
        }
    }
    $registry = Get-QdmRegistrySymbols
    foreach ($s in $SourceList) {
        $dropped = @((@($s.M1) + @($s.Tick) | Sort-Object -Unique) | Where-Object { $registry -notcontains $_ })
        if ($dropped.Count -gt 0) {
            Write-Warning "[$($s.Name)] registration FAILED for: $($dropped -join ', ') - source may not offer these names. Dropped from this run."
        }
        $s.M1   = @($s.M1   | Where-Object { $registry -contains $_ })
        $s.Tick = @($s.Tick | Where-Object { $registry -contains $_ })
        Write-Host "[$($s.Name)] validated: $($s.M1.Count) M1, $($s.Tick.Count) tick"
    }
}

$CheckUpdate = {
    param($log)
    if (-not (Test-Path $log)) { return $false }
    $m = Select-String -Path $log -Pattern 'TotalProgressSymbol, (\d+) / (\d+)' | Select-Object -Last 1
    if ($m) {
        $n = [int]$m.Matches[0].Groups[1].Value; $t = [int]$m.Matches[0].Groups[2].Value
        if ($t -gt 0 -and $n -eq $t) { return $true }
    }
    return $false
}

# PHASE 1 - update all registered symbols
Invoke-QdmPhase -Lines @("-data action=update") -CompleteCheck $CheckUpdate `
                -QuiesceSec $UpdateQuiesceSec -TimeoutMin $UpdateTimeoutMin -Phase "update"

# common export bits
$tickFmt = 'format="Generic tick format (comma delimited)"'   # default format is a BAR format -> zero-price garbage for ticks
if ($Full) {
    $fromArg = if ($FullFromDate -ne "") { "datefrom=$FullFromDate " } else { "" }
} else {
    $fromArg = "datefrom=" + (Get-Date).AddDays(-$WindowDays).ToString("yyyy.MM.dd") + " "
}

function Wait-TickFolderDrained { param([string]$Folder, [int]$MaxWaitMin = 90)
    $deadline = (Get-Date).AddMinutes($MaxWaitMin)
    $lastNames = ""
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-ChildItem $Folder -Filter *.csv -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) { return }
        $names = ($left | Sort-Object Name | ForEach-Object { $_.Name }) -join ","
        if ($names -ne $lastNames) {
            # file set changed since last check - some progress is happening, don't alarm yet
            $lastNames = $names
        }
        Write-Host "  waiting for QdmImporter to consume $($left.Count) tick file(s) before next batch..."
        Start-Sleep -Seconds 60
    }
    $stuck = @(Get-ChildItem $Folder -Filter *.csv -ErrorAction SilentlyContinue)
    Write-Warning "TICK folder not drained after $MaxWaitMin min - is the QdmImporter service running?"
    if ($stuck.Count -gt 0) {
        Write-Warning "Files still present (possibly stuck - check the service's Experts log for why these are being skipped):"
        foreach ($f in $stuck) {
            $ageMin = [math]::Round(((Get-Date) - $f.LastWriteTime).TotalMinutes, 1)
            Write-Warning "  $($f.Name)  ($([math]::Round($f.Length/1MB,1)) MB, last written $ageMin min ago)"
        }
    }
    Write-Warning "Continuing anyway - a persistently stuck file will cause this warning on every future batch until removed or fixed."
}

# PHASE 2 + 3 - per-source exports
foreach ($s in $SourceList) {
    $tzArg = if ($s.Timezone -ne "") { "timezone=$($s.Timezone) " } else { "" }

    if ($s.M1.Count -gt 0) {
        $outDir = (Join-Path $outM1Root $s.Name) -replace '\\','/'
        $syms   = $s.M1 -join ","
        Invoke-QdmPhase -Lines @("-data action=export symbols=$syms timeframe=M1 ${fromArg}${tzArg}outputdir=$outDir") `
                        -CompleteCheck (New-ExportCheck -Expected $s.M1.Count) `
                        -QuiesceSec $ExportQuiesceSec -TimeoutMin $ExportTimeoutMin -Phase "export-m1-$($s.Name)"
    }

    if ($s.Tick.Count -gt 0) {
        $outDir  = Join-Path $outTickRoot $s.Name
        $outDirF = $outDir -replace '\\','/'
        $batchNum = 0
        for ($i = 0; $i -lt $s.Tick.Count; $i += $TickBatchSize) {
            $batchNum++
            $batch = @($s.Tick[$i..([Math]::Min($i + $TickBatchSize - 1, $s.Tick.Count - 1))])
            $syms  = $batch -join ","
            Write-Host "`n--- [$($s.Name)] TICK batch $batchNum : $syms ---"
            Invoke-QdmPhase -Lines @("-data action=export symbols=$syms timeframe=TICK ${fromArg}${tzArg}$tickFmt outputdir=$outDirF") `
                            -CompleteCheck (New-ExportCheck -Expected $batch.Count) `
                            -QuiesceSec $ExportQuiesceSec -TimeoutMin $ExportTimeoutMin -Phase "export-tick-$($s.Name)-b$batchNum"
            Wait-TickFolderDrained -Folder $outDir
        }
    }
}

$exported = @(Get-ChildItem $Mt5Common -Recurse -Filter "*.csv" |
              Where-Object { $_.DirectoryName -notmatch "\\done" }).Count
Write-Host "`nDone. $exported CSV file(s) currently waiting under $Mt5Common"
Write-Host "(imported files are handled per the service's InpDonePolicy)"

Exit-Run 0
