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
    0. License refresh: open the QDM GUI once, let it re-verify online, close it.
       (qdmcli can only READ the license file - only the GUI refreshes it. Doing
       this before every run keeps the headless CLI from silently no-op'ing on an
       expired license file.)
    1. Validate config symbols against QDM's registry; auto-register missing
       symbols under their configured source
    2. -data action=update              (incremental download, all registered)
    3. Per source: M1 export (single session)
    4. Per source: TICK export in small sequential batches

  Completion detection per phase (qdmcli -data jobs are ASYNC; -exit in the
  command file kills them instantly, so phases run WITHOUT -exit):
    1. qdmcli exits on its own (it does, once all jobs finish)
    2. completion markers in the phase log
    3. FALLBACK: phase log AND the QDM store tree both stop moving for a long
       window -> stop + WARNING
  The primary activity signal is the LOG FILE read through an open handle -
  never directory-listed CSV sizes, which NTFS updates lazily for open files.
  Download phases add a second signal (file count/bytes/newest-mtime under
  user\data\History), because qdmcli goes silent on stdout for many minutes
  while flushing one large tick store: a log-only window killed a live refetch
  mid-write and left the symbols still queued behind it with no data at all.

.USAGE
  Run (any cadence) : powershell -ExecutionPolicy Bypass -File qdm-mt5-autosync.ps1
  Full export       :  ... qdm-mt5-autosync.ps1 -Full
  Setup             :  ... qdm-mt5-autosync.ps1 -Setup    (bulk-register config symbols)
  Cleanup           :  ... qdm-mt5-autosync.ps1 -Cleanup  (delete '(n)' duplicate symbols)
  Warehouse build   :  ... qdm-mt5-autosync.ps1 -Build    (per-year shards + manifest, for other hosts)
  Skip license GUI  :  ... qdm-mt5-autosync.ps1 -NoLicenseRefresh

.SCHEDULE (run once, elevated - adjust the script path):
  schtasks /Create /TN "QDM-MT5-AutoSync" /TR "powershell -ExecutionPolicy Bypass -File <repo>\qdm-mt5-autosync.ps1" /SC DAILY /ST 09:00 /RL HIGHEST /F
#>

param(
    [switch]$Full,
    [switch]$Setup,
    [switch]$Cleanup,
    [switch]$Build,              # build per-year warehouse shards + manifest, then exit
    [switch]$Publish,            # transfer shards a consumer is missing, then exit
    [switch]$Reindex,            # rebuild the manifest from shards on disk (no re-export), then exit
    [string]$Consumer = "",      # -Publish: which consumer (default: all configured)
    [switch]$Redownload,         # DESTRUCTIVE: clear the named symbols in QDM and re-fetch full history
    [string]$Symbols = "",       # -Redownload: explicit csv symbol list (required; there is no "all")
    [switch]$Force,              # -Redownload: skip the interactive confirmation
    [switch]$Resume,             # -Redownload: SKIP the clear, just re-run the fetch (for an interrupted refetch)
    [switch]$NoLicenseRefresh,   # skip the GUI open/verify/close pre-step
    [string]$ConfigPath = "",
    [string]$OnlySource = "",    # limit run to one source, e.g. -OnlySource darwinex
    [string]$OnlySymbols = "",   # limit run to specific symbols (csv), e.g. -OnlySymbols "XAUUSD,USDJPY"
    [int]$BuildFromYear = 0,     # -Build: override Warehouse.FromYear
    [int]$BuildToYear   = 0      # -Build: override Warehouse.ToYear
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

# --- reconcile + backfill ------------------------------------------------------
# Global fallbacks, overridden per-source in the Sources:<name> block.
$GlobalProviderLag = [int](Get-CfgVal "ProviderLagDays" 2)
$GlobalBackfill    = [int](Get-CfgVal "BackfillWindowDays" 14)
if ($cfg.PSObject.Properties.Name -contains "Reconcile") { $recon = $cfg.Reconcile } else { $recon = $null }
$ReconcileEnabled = if ($recon -and $recon.PSObject.Properties.Name -contains "Enabled" -and $null -ne $recon.Enabled) { [bool]$recon.Enabled } else { $true }
if ($recon -and $recon.PSObject.Properties.Name -contains "ProviderLagDays") { $GlobalProviderLag = [int]$recon.ProviderLagDays }
$ReconcileMarginDays = if ($recon -and $recon.PSObject.Properties.Name -contains "MarginDays") { [int]$recon.MarginDays } else { 1 }
$ReconcileStatusDir  = if ($recon -and $recon.PSObject.Properties.Name -contains "StatusDir" -and "$($recon.StatusDir)" -ne "") { [string]$recon.StatusDir } else { "" }
$ReconcileReportDir  = if ($recon -and $recon.PSObject.Properties.Name -contains "ReportDir" -and "$($recon.ReportDir)" -ne "") { [string]$recon.ReportDir } else { "" }

# --- sources: name -> { Timezone, M1Symbols[], TickSymbols[] } --------------
$SourceList = @()   # array of PSCustomObject: Name, Timezone, M1, Tick
if ($cfg.PSObject.Properties.Name -contains "Sources") {
    foreach ($p in $cfg.Sources.PSObject.Properties) {
        if ($p.Name -like "_*") { continue }
        $s = $p.Value
        $SourceList += [pscustomobject]@{
            Name     = $p.Name
            Timezone = if ($s.PSObject.Properties.Name -contains "Timezone") { [string]$s.Timezone } else { "" }
            ProviderLagDays   = if ($s.PSObject.Properties.Name -contains "ProviderLagDays")   { [int]$s.ProviderLagDays }   else { $GlobalProviderLag }
            BackfillWindowDays= if ($s.PSObject.Properties.Name -contains "BackfillWindowDays"){ [int]$s.BackfillWindowDays } else { $GlobalBackfill }
            M1       = if ($s.PSObject.Properties.Name -contains "M1Symbols")   { @($s.M1Symbols) }   else { @() }
            Tick     = if ($s.PSObject.Properties.Name -contains "TickSymbols") { @($s.TickSymbols) } else { @() }
        }
    }
} elseif ($cfg.PSObject.Properties.Name -contains "M1Symbols") {
    # backward-compatible flat config
    $SourceList += [pscustomobject]@{
        Name     = [string](Get-CfgVal "DataSource" "dukascopy")
        Timezone = ""
        ProviderLagDays   = $GlobalProviderLag
        BackfillWindowDays= $GlobalBackfill
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
# A full refetch is a different animal from a daily update: it downloads years,
# not days, and both its stdout and its on-disk flushes come in long bursts.
$RedownloadQuiesceSec = Get-WdVal "RedownloadQuiesceSec" 3600
$RedownloadTimeoutMin = Get-WdVal "RedownloadTimeoutMin" 2880
$ExportQuiesceSec = Get-WdVal "ExportQuiesceSec" 600
$ExportTimeoutMin = Get-WdVal "ExportTimeoutMin" 480
$MinPhaseRunSec   = Get-WdVal "MinPhaseRunSec"   120
$DrainWaitMin     = Get-WdVal "DrainWaitMin"     90

# Update-phase completion: qdmcli logs a running symbol tally. Defined here,
# above the -Build/-Redownload blocks, because those run before the main
# pipeline and need it too.
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

# Default export format is a BAR format, which yields zero-price garbage for
# ticks. Defined here rather than mid-pipeline because -Build needs it too.
$tickFmt = 'format="Generic tick format (comma delimited)"'

# --- warehouse (shard + manifest layout) --------------------------
# Only read when -Build/-Publish are used; absent means those switches error out
# rather than guessing a layout other machines would then depend on.
$wh = if ($cfg.PSObject.Properties.Name -contains "Warehouse") { $cfg.Warehouse } else { $null }
function Get-WhVal($name, $default) {
    if ($wh -and ($wh.PSObject.Properties.Name -contains $name) -and $null -ne $wh.$name -and "$($wh.$name)" -ne "") { return $wh.$name }
    return $default
}
$WhRoot       = [string](Get-WhVal "Root" "")
$WhClock      = [string](Get-WhVal "Clock" "utc")
$WhTimezone   = [string](Get-WhVal "Timezone" "Etc/UCT")
$WhTimeframes = @(Get-WhVal "Timeframes" @("M1"))
$WhSources    = @(Get-WhVal "Sources" @())
$WhFromYear   = [int](Get-WhVal "FromYear" 2011)
$WhToYear     = [int](Get-WhVal "ToYear" 0)
if ($BuildFromYear -gt 0) { $WhFromYear = $BuildFromYear }
if ($BuildToYear   -gt 0) { $WhToYear   = $BuildToYear }
if ($WhToYear -le 0) { $WhToYear = (Get-Date).Year }

# --- license refresh (license-expiry.md): open the GUI once so its online
# verification refreshes the local license file before any qdmcli phase ---------
$lref = if ($cfg.PSObject.Properties.Name -contains "LicenseRefresh") { $cfg.LicenseRefresh } else { $null }
$LicenseRefreshEnabled = if ($lref -and $lref.PSObject.Properties.Name -contains "Enabled" -and $null -ne $lref.Enabled) { [bool]$lref.Enabled } else { $true }
if ($NoLicenseRefresh) { $LicenseRefreshEnabled = $false }
$LicenseRefreshWaitSec   = if ($lref -and $lref.PSObject.Properties.Name -contains "WaitSec")   { [int]$lref.WaitSec }   else { 90 }
$LicenseRefreshSettleSec = if ($lref -and $lref.PSObject.Properties.Name -contains "SettleSec") { [int]$lref.SettleSec } else { 10 }

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

# --- QDM license health check ------------------------------------------------
# QDM validates a locally-stored license file at every startup. The headless CLI
# (qdmcli) only READS that file - it can never refresh it - while the GUI re-verifies
# online on every launch. If the GUI isn't opened for a long stretch, the file's
# validation window lapses and every CLI phase prints "Missing license." then exits
# in ~15s, making the whole run look like a fast no-op. Detect it explicitly and
# abort with a clear message instead.
function Test-LicenseFailure { param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return $false }
    return ($null -ne (Select-String -Path $LogPath -Pattern 'Missing license','License file validation has expired' -ErrorAction SilentlyContinue | Select-Object -First 1))
}

function Assert-NoLicenseFailure { param([string]$LogPath, [string]$Phase)
    if (-not (Test-LicenseFailure $LogPath)) { return }
    Write-Host "`nQDM LICENSE FAILURE in phase [$Phase]." -ForegroundColor Red
    Write-Host "QDM's local license file validation has expired and the pre-run GUI refresh" -ForegroundColor Red
    Write-Host "did not fix it (or was skipped via -NoLicenseRefresh). Open QuantDataManager.exe" -ForegroundColor Red
    Write-Host "once and confirm it shows the main window, then re-run this sync." -ForegroundColor Red
    Write-Host "Phase log: $LogPath`n" -ForegroundColor Red
    Exit-Run 1
}

# --- QDM license refresh ------------------------------------------------------
# qdmcli can only READ the local license file; the GUI re-verifies it online on
# every launch. Open the GUI once, wait for the "Pro version" title, close it.
# Runs before any qdmcli phase so the headless CLI never hits an expired file.
function Refresh-QdmLicense {
    if (-not $LicenseRefreshEnabled) {
        Write-Host "License refresh: disabled (config/flag) - skipping GUI open/verify/close." -ForegroundColor Yellow
        return
    }
    $guiExe = Join-Path $QdmDir "QuantDataManager.exe"
    if (-not (Test-Path $guiExe)) {
        Write-Warning "License refresh: QuantDataManager.exe not found at $guiExe - skipping."
        return
    }

    Write-Host "`n=== LICENSE REFRESH: opening QDM GUI to re-verify license online ===" -ForegroundColor Cyan
    Start-Process -FilePath $guiExe -WorkingDirectory $QdmDir | Out-Null

    $uiLogDir  = Join-Path $QdmDir "user\log\QuantDataManager_ui"
    $deadline  = (Get-Date).AddSeconds($LicenseRefreshWaitSec)
    $ok        = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3

        # 1) window title check via the UI process main window
        $uiProc = Get-Process QuantDataManager_ui -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($uiProc -and $uiProc.MainWindowTitle -match 'Pro version') { $ok = $true; break }

        # 2) fallback: latest Electron UI log shows the Pro version title event
        $uiLog = Get-ChildItem $uiLogDir -Filter "log_*.log" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($uiLog) {
            $tail = Get-Content $uiLog.FullName -Tail 40 -ErrorAction SilentlyContinue
            if ($tail -match 'Pro version') { $ok = $true; break }
        }
    }

    if ($ok) {
        Write-Host "License verified (GUI shows Pro version). Leaving GUI open $LicenseRefreshSettleSec s, then closing." -ForegroundColor Green
        Start-Sleep -Seconds $LicenseRefreshSettleSec
    } else {
        Write-Warning "License refresh: did not confirm 'Pro version' within ${LicenseRefreshWaitSec}s. License may still be invalid - the phase checks below will catch it."
    }

    # close the GUI again (QDM is single-instance; the pipeline needs it closed)
    foreach ($name in @('QuantDataManager', 'QuantDataManager_ui', 'QDataManager_nocheck')) {
        Get-Process $name -ErrorAction SilentlyContinue |
            ForEach-Object { & taskkill /PID $_.Id /T /F 2>$null | Out-Null }
    }
    Start-Sleep 3
    Write-Host "=== LICENSE REFRESH: GUI closed ===`n" -ForegroundColor Cyan
}

# --- no-data exports ----------------------------------------------------------
# QDM writes a CSV even when the requested range holds nothing: 0 bytes for a
# bar export, a lone header line ("DateTime,Bid,Ask,Volume") for a tick export.
# Neither can EVER be imported - QdmImporter refuses a zero-length file (it
# cannot tell empty from mid-write) and a header-only file parses to zero rows.
# Left in place they accumulate in the watch tree forever and make every future
# Wait-TickFolderDrained block for its full timeout, on every batch, on every
# run. Detect and remove them instead.
function Test-ExportHasData { param([string]$Path)
    try {
        $len = (Get-Item $Path -ErrorAction Stop).Length
        if ($len -le 0)    { return $false }
        if ($len -gt 4096) { return $true }        # far too large to be header-only
        foreach ($line in (Get-Content $Path -TotalCount 5 -ErrorAction Stop)) {
            if ($line -match '^\s*(19|20)\d\d') { return $true }   # a real data row
        }
        return $false
    } catch { return $true }                       # unreadable = still being written; leave it
}

function Remove-DatalessExports {
    param([string]$Folder, [int]$MinAgeMin = 5, [switch]$Recurse)
    if (-not (Test-Path $Folder)) { return 0 }
    $cutoff = (Get-Date).AddMinutes(-$MinAgeMin)
    $cand = @(Get-ChildItem $Folder -Filter *.csv -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Length -le 4096 })
    $n = 0
    foreach ($f in $cand) {
        if (Test-ExportHasData $f.FullName) { continue }
        Write-Warning "  no-data export removed: $($f.Name) ($($f.Length) bytes - QDM had nothing for the requested range)"
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        $n++
    }
    return $n
}

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

# --- clear no-data exports left behind by earlier runs ----------------------
$purged = 0
foreach ($root in @($outM1Root, $outTickRoot)) {
    $purged += (Remove-DatalessExports -Folder $root -MinAgeMin 5 -Recurse)
}
if ($purged -gt 0) { Write-Host "Cleared $purged no-data export(s) left by earlier runs." }

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " CONFIG LOADED: $ConfigPath" -ForegroundColor Cyan
Write-Host " QDM dir        : $QdmDir" -ForegroundColor Cyan
Write-Host " MT5 Common\QDM : $Mt5Common" -ForegroundColor Cyan
foreach ($s in $SourceList) {
    $tz = if ($s.Timezone) { $s.Timezone } else { "native/UTC" }
    Write-Host " [$($s.Name)] tz=$tz lag=$($s.ProviderLagDays)d backfill=$($s.BackfillWindowDays)d | M1: $($s.M1.Count) | Tick: $($s.Tick.Count)" -ForegroundColor Cyan
    Write-Host "    M1  : $($s.M1 -join ', ')" -ForegroundColor Cyan
    if ($s.Tick.Count -gt 0) { Write-Host "    Tick: $($s.Tick -join ', ')" -ForegroundColor Cyan }
}
Write-Host " Window days: $WindowDays | Full-seed from: $(if ($FullFromDate) {$FullFromDate} else {'(all history)'}) | Tick batch: $TickBatchSize" -ForegroundColor Cyan
Write-Host " Reconcile: $ReconcileEnabled | global lag: $GlobalProviderLag d | margin: $ReconcileMarginDays d" -ForegroundColor Cyan
Write-Host " License refresh: $(if($LicenseRefreshEnabled){'on (GUI open/verify/close pre-step)'}else{'off'})" -ForegroundColor Cyan
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
# -Publish never touches QDM - it only moves files -Build already produced. The
# single-instance check and the licence refresh both apply to qdmcli work only,
# and would block a publish for no reason (an open GUI aborts the run outright).
if (-not $Publish) {
    Assert-QdmFree

    # --- pre-step: refresh the QDM license via a brief GUI open/verify/close ---
    Refresh-QdmLicense
}

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
    Assert-NoLicenseFailure $log "sync"
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

# A second liveness signal, independent of stdout.
#
# qdmcli's progress lines stop for long stretches while it flushes one big tick
# store: measured on a 9-symbol refetch, stdout went quiet at 22:34 while
# XAUUSD_TICK.dat kept growing until 22:42 - so a log-only quiet window killed a
# healthy download mid-write and left four queued symbols with no data at all.
# Watching the store tree as well means "quiet" requires BOTH the log and the
# data on disk to stop moving.
#
# Export phases pass their staging/output folder here too. NTFS updates size and
# mtime lazily for a file held open, so those two components can read stale for
# an in-progress CSV - but the file COUNT still moves as each symbol finishes,
# and a stale reading can only ever extend the wait, never cut it short. The
# absolute TimeoutMin remains the hard bound.
function Get-StoreProgressStamp { param([string[]]$Paths)
    if (-not $Paths -or $Paths.Count -eq 0) { return "" }
    $bytes = [int64]0; $newest = [int64]0; $count = 0
    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) { continue }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($p, '*', 'AllDirectories')) {
                $fi = New-Object System.IO.FileInfo $f
                $bytes += $fi.Length; $count++
                if ($fi.LastWriteTimeUtc.Ticks -gt $newest) { $newest = $fi.LastWriteTimeUtc.Ticks }
            }
        } catch { }   # a file vanishing mid-enumeration is itself activity
    }
    return "$count|$bytes|$newest"
}

# --- async phases -----------------------------------------------------------
function Invoke-QdmPhase {
    param(
        [string[]]$Lines,
        [scriptblock]$CompleteCheck,
        [int]$QuiesceSec, [int]$TimeoutMin, [string]$Phase,
        [string[]]$ProgressPaths
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
    $lastStamp = ""
    $endReason = ""

    $watching = if ($ProgressPaths) { "log + $($ProgressPaths.Count) store path(s)" } else { "log only" }
    Write-Host "[$Phase] started (pid $($p.Id)). Watching for completion ($watching, fallback quiet window: $QuiesceSec s)..."
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

        $len   = Get-LiveFileLength $log
        $stamp = Get-StoreProgressStamp $ProgressPaths
        if ($len -ne $lastLen -or $stamp -ne $lastStamp) {
            $lastLen = $len; $lastStamp = $stamp; $stableSince = Get-Date
        } elseif ((Get-Date) -gt $minRunOk -and ((Get-Date) - $stableSince).TotalSeconds -ge $QuiesceSec) {
            $what = if ($ProgressPaths) { "phase log AND data store" } else { "phase log" }
            Write-Warning "[$Phase] FALLBACK STOP: $what frozen for $QuiesceSec s and no completion marker."
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

    # license expiry makes every phase a ~15s no-op; bail loudly instead of plowing on
    Assert-NoLicenseFailure $log $Phase
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
    $regRunLog = Join-Path $LogDir "registry_run_$stamp.log"
    ("-symbol action=list > " + ($listLog -replace '\\','/'), "-exit") | Set-Content -Path $cmdFile -Encoding ASCII
    cmd /c "`"$QdmCli`" -run file=$(($cmdFile -replace '\\','/')) > `"$regRunLog`" 2>&1"
    Assert-NoLicenseFailure $regRunLog "registry"
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

# =============================================================================
# -Build : warehouse shards + manifest
#
# Turns this machine into a source other hosts can consume without a QDM licence.
# One CSV per symbol per year, in a
# clock named by the path, plus a manifest carrying a sha256 per shard so a
# consumer can diff instead of re-transferring.
#
# Exports run ONE YEAR PER PHASE, all symbols of a source together. Not one
# phase per symbol-year: qdmcli's JVM start alone would then cost hours over
# ~500 invocations. Not all years in one phase either: QDM silently drops an
# export job for a symbol already busy in another job, and the same symbol
# appears in every year.
# =============================================================================

# Manifests cross a host boundary into Node/Python consumers, and PowerShell
# 5.1's `Set-Content -Encoding UTF8` writes a BOM that JSON.parse rejects
# outright. Always write manifest JSON BOM-less.
function Write-JsonFile([object]$Obj, [string]$Path) {
    $json = $Obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ShardRelPath([string]$Source, [string]$Symbol, [string]$Tf, [int]$Year) {
    return "$Source/$WhClock/$Symbol/$Tf/$Symbol-$Tf-$Year.csv"
}

# First/last data timestamp and row count, in one pass, without loading the file.
function Measure-Shard([string]$Path) {
    $rows = 0; $first = ""; $last = ""
    $sr = [System.IO.StreamReader]::new($Path)
    try {
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line.Length -lt 8) { continue }
            $c = $line[0]
            if ($c -lt '0' -or $c -gt '9') { continue }     # header or junk
            if ($rows -eq 0) { $first = $line }
            $last = $line
            $rows++
        }
    } finally { $sr.Dispose() }
    $stamp = { param($l) if ($l -eq "") { "" } else { ($l -split ',')[0..1] -join ' ' } }
    return @{ rows = $rows; from = (& $stamp $first); to = (& $stamp $last) }
}

# A shard that is on disk and validates belongs in the manifest, whether or not
# THIS run produced it.
#
# Build-Warehouse records only what it built plus what the previous manifest
# already listed. So a good shard becomes invisible the moment those two miss it
# at once - and they do: if the QDM store loses a year, the build can no longer
# re-export it, and if the manifest was reset, nothing carries the existing file
# forward. Measured: a killed download damaged the EURJPY store, the next build
# rejected 2011-2025, and 15 sound 20.9 MB shards - already published and
# sha256-verified on the consumer - dropped out of the manifest, silently
# removing 15 years from the reconstruction feed while the files sat untouched.
#
# Adoption applies the SAME two tests as the build (non-empty, and the data's own
# year matches the shard's year), so the 1-row nearest-record placeholders QDM
# returns for a range it lacks are rejected here exactly as they are there.
function Add-OrphanShards {
    param([object]$Artifacts)

    $have = @{}
    foreach ($a in $Artifacts) { if ($null -ne $a) { $have[$a.path] = $true } }

    $adopted = 0; $rejected = 0
    $rootLen = $WhRoot.TrimEnd('\').Length + 1
    foreach ($f in @(Get-ChildItem $WhRoot -Recurse -File -Filter '*.csv' -ErrorAction SilentlyContinue)) {
        $rel = ($f.FullName.Substring($rootLen)) -replace '\\','/'
        if ($rel -like '.staging/*') { continue }
        if ($have.ContainsKey($rel)) { continue }

        $parts = $rel -split '/'
        if ($parts.Count -ne 5) { continue }
        $src = $parts[0]; $clk = $parts[1]; $sym = $parts[2]; $tf = $parts[3]
        if ($clk -ne $WhClock) { continue }          # manifest declares one clock
        if ($parts[4] -notmatch "^$([regex]::Escape($sym))-$([regex]::Escape($tf))-(\d{4})\.csv$") { continue }
        $year = $Matches[1]

        $m = Measure-Shard $f.FullName
        $fromYear = if ($m.from.Length -ge 4) { $m.from.Substring(0,4) } else { "" }
        $toYear   = if ($m.to.Length   -ge 4) { $m.to.Substring(0,4) }   else { "" }
        if ($m.rows -eq 0 -or $fromYear -gt $year -or $toYear -lt $year) {
            Write-Host "  reject $rel (rows=$($m.rows), nearest $($m.from)) - placeholder, not adopted"
            $rejected++
            continue
        }

        $Artifacts.Add([pscustomobject]@{
            class      = "csv-shard"
            source     = $src
            clock      = $clk
            symbol     = $sym
            tf         = $tf
            period     = $year
            path       = $rel
            bytes      = $f.Length
            sha256     = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
            rows       = $m.rows
            from       = $m.from
            to         = $m.to
            exportedAt = $f.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        })
        $adopted++
        Write-Host ("  adopt  {0}: {1:N0} rows ({2} .. {3})" -f $rel, $m.rows, $m.from, $m.to)
    }
    return @{ adopted = $adopted; rejected = $rejected }
}

function Build-Warehouse {
    if ($WhRoot -eq "") {
        Write-Error "-Build needs a Warehouse block in config.json (see config.example.json)."
        Exit-Run 1
    }
    $sources = @($SourceList | Where-Object { $WhSources.Count -eq 0 -or $WhSources -contains $_.Name })
    if ($sources.Count -eq 0) { Write-Error "-Build: Warehouse.Sources matches no configured source."; Exit-Run 1 }

    $staging = Join-Path $WhRoot ".staging"
    New-Item -ItemType Directory -Force -Path $WhRoot, $staging | Out-Null

    # Existing manifest: shards already recorded are skipped, so a re-run is
    # cheap and an interrupted build resumes. The current year always rebuilds.
    $manifestPath = Join-Path $WhRoot "manifest.json"
    $known = @{}
    if (Test-Path $manifestPath) {
        try {
            $old = Get-Content $manifestPath -Raw | ConvertFrom-Json
            foreach ($a in @($old.artifacts)) { $known[$a.path] = $a }
        } catch { Write-Warning "Existing manifest unreadable - rebuilding it from scratch." }
    }

    $thisYear = (Get-Date).Year
    $artifacts = [collections.generic.list[object]]::new()
    $built = 0; $skipped = 0

    Write-Host "`n=== BUILD: warehouse shards ===" -ForegroundColor Cyan
    Write-Host " Root  : $WhRoot"
    Write-Host " Clock : $WhClock (qdmcli timezone=$WhTimezone)"
    Write-Host " Years : $WhFromYear..$WhToYear | Timeframes: $($WhTimeframes -join ',')"

    foreach ($tf in $WhTimeframes) {
        foreach ($s in $sources) {
            $syms = if ($tf -eq "TICK") { $s.Tick } else { $s.M1 }
            if ($syms.Count -eq 0) { continue }

            for ($year = $WhFromYear; $year -le $WhToYear; $year++) {
                # which symbols still need this year?
                $todo = @($syms | Where-Object {
                    $rel = Get-ShardRelPath $s.Name $_ $tf $year
                    $full = Join-Path $WhRoot ($rel -replace '/','\')
                    -not ($known.ContainsKey($rel) -and (Test-Path $full) -and $year -lt $thisYear)
                })
                foreach ($sym in @($syms | Where-Object { $todo -notcontains $_ })) {
                    $artifacts.Add($known[(Get-ShardRelPath $s.Name $sym $tf $year)]); $skipped++
                }
                if ($todo.Count -eq 0) { continue }

                $stage = Join-Path $staging "$($s.Name)_$tf`_$year"
                if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Force -Path $stage | Out-Null
                $stageF = $stage -replace '\\','/'

                $fmt = if ($tf -eq "TICK") { $tickFmt + " " } else { "" }
                Write-Host "`n--- [$($s.Name)] $tf $year : $($todo.Count) symbol(s) ---"
                Invoke-QdmPhase -Lines @("-data action=export symbols=$($todo -join ',') timeframe=$tf datefrom=$year.01.01 dateto=$year.12.31 timezone=$WhTimezone $fmt" + "outputdir=$stageF") `
                                -CompleteCheck (New-ExportCheck -Expected $todo.Count) `
                                -QuiesceSec $ExportQuiesceSec -TimeoutMin $ExportTimeoutMin `
                                -Phase "build-$tf-$($s.Name)-$year" `
                                -ProgressPaths @($stage)

                foreach ($f in @(Get-ChildItem $stage -Filter *.csv -File -ErrorAction SilentlyContinue)) {
                    # QDM names exports "<SYMBOL>-<TF>-No Session.csv"
                    $sym = ($f.BaseName -split '-')[0]
                    if ($todo -notcontains $sym) {
                        Write-Warning "  unexpected export '$($f.Name)' (symbol '$sym' not requested) - left in staging"
                        continue
                    }
                    $m = Measure-Shard $f.FullName
                    if ($m.rows -eq 0) {
                        Write-Warning "  $sym $year : no data - shard not created"
                        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                        continue
                    }
                    # Asked for a range it holds nothing in, QDM does NOT return an
                    # empty file - it returns the single nearest bar it does have,
                    # dated outside the requested year. A row count above zero is
                    # therefore not evidence of data for THIS year, and without this
                    # check the warehouse fills with 1-row shards whose manifest
                    # entry claims a year it has no data for. Verify the range
                    # instead of trusting that a file came back.
                    $fromYear = if ($m.from.Length -ge 4) { $m.from.Substring(0,4) } else { "" }
                    $toYear   = if ($m.to.Length   -ge 4) { $m.to.Substring(0,4) }   else { "" }
                    if ($fromYear -gt "$year" -or $toYear -lt "$year") {
                        Write-Warning "  $sym $year : QDM holds no data for this year (nearest bar $($m.from)) - shard not created"
                        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                        continue
                    }
                    $rel  = Get-ShardRelPath $s.Name $sym $tf $year
                    $dest = Join-Path $WhRoot ($rel -replace '/','\')
                    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
                    Move-Item $f.FullName $dest -Force
                    $artifacts.Add([pscustomobject]@{
                        class      = "csv-shard"
                        source     = $s.Name
                        clock      = $WhClock
                        symbol     = $sym
                        tf         = $tf
                        period     = "$year"
                        path       = $rel
                        bytes      = (Get-Item $dest).Length
                        sha256     = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
                        rows       = $m.rows
                        from       = $m.from
                        to         = $m.to
                        exportedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    })
                    $built++
                    Write-Host ("  {0} {1}: {2:N0} rows, {3:N1} MB" -f $sym, $year, $m.rows, ((Get-Item $dest).Length / 1MB))
                }
                Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Never drop a sound shard just because this run could not rebuild it.
    Write-Host "`n--- adopting valid shards on disk that this run did not record ---"
    $orph = Add-OrphanShards -Artifacts $artifacts

    Write-JsonFile ([pscustomobject]@{
        schema      = 1
        warehouse   = $env:COMPUTERNAME
        generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        clock       = $WhClock
        timezone    = $WhTimezone
        artifacts   = @($artifacts | Where-Object { $null -ne $_ })
    }) $manifestPath

    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "`n=== BUILD done: $built shard(s) built, $skipped already current, $($orph.adopted) adopted, $($orph.rejected) placeholder(s) rejected ===" -ForegroundColor Green
    Write-Host "Manifest: $manifestPath ($($artifacts.Count) artifact(s))"
}

if ($Build) { Build-Warehouse; Exit-Run 0 }

# -Reindex : rebuild the manifest from what is actually on disk, without
# re-exporting anything. Cheap repair for the case above - the shards already
# exist and are already on the consumer, so regenerating them from QDM would
# cost hours to produce identical bytes.
function Invoke-Reindex {
    if ($WhRoot -eq "") { Write-Error "-Reindex needs a Warehouse block in config.json."; Exit-Run 1 }
    $manifestPath = Join-Path $WhRoot "manifest.json"
    $artifacts = [collections.generic.list[object]]::new()
    if (Test-Path $manifestPath) {
        try {
            $old = Get-Content $manifestPath -Raw | ConvertFrom-Json
            foreach ($a in @($old.artifacts)) { $artifacts.Add($a) }
        } catch { Write-Warning "Existing manifest unreadable - rebuilding it from disk alone." }
    }
    $before = $artifacts.Count
    Write-Host "`n=== REINDEX: $WhRoot ===" -ForegroundColor Cyan
    Write-Host " manifest currently lists $before artifact(s)"
    $orph = Add-OrphanShards -Artifacts $artifacts

    Write-JsonFile ([pscustomobject]@{
        schema      = 1
        warehouse   = $env:COMPUTERNAME
        generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        clock       = $WhClock
        timezone    = $WhTimezone
        artifacts   = @($artifacts | Where-Object { $null -ne $_ })
    }) $manifestPath

    Write-Host "`n=== REINDEX done: $($orph.adopted) adopted, $($orph.rejected) placeholder(s) rejected ===" -ForegroundColor Green
    Write-Host "Manifest: $manifestPath ($before -> $($artifacts.Count) artifact(s))"
    Write-Host "Run -Publish to record the adopted shards on the consumer."
}

if ($Reindex) { Invoke-Reindex; Exit-Run 0 }

# =============================================================================
# -Redownload : wipe named symbols in QDM and re-fetch their full history
#
# For symbols whose LOCAL store has holes. QDM's registry listing is not
# evidence of local coverage - its "Date from/to" and "Total records" describe
# what the SOURCE offers, so a symbol can list 2003-2026 / 200M records and
# still hold nothing locally for 2014-2025. The reliable tell is an export:
# asked for a range it has no local data in, QDM returns the first record at or
# after that range instead of an empty file.
#
# `-data action=update` alone does NOT repair this - it extends the stored range
# forward, it does not backfill interior holes. Clearing first is what forces a
# full re-fetch, which is why this is destructive and explicit.
#
# DESTRUCTIVE and SLOW: clearing discards the data the symbol does hold, and a
# full tick re-download is hours per symbol. If it is interrupted the symbol is
# left with less than it started with, so pilot one symbol before a batch.
# =============================================================================
# Single-symbol, single-year export used to prove what QDM actually holds
# LOCALLY. Deliberately NOT routed through Invoke-QdmSync: that appends `-exit`,
# which kills an async `-data` job instantly (see the header) - the probe would
# then report "no file" for every symbol and read as a failed re-download when
# nothing had been tested at all. Launch it like a phase and wait for qdmcli to
# exit on its own.
#
# Returns $null when no file appeared, else a record with Rows/From/To/InRange.
# InRange is the whole point: a row count above zero proves nothing, because QDM
# answers a range it lacks with the nearest record outside it.
function Invoke-QdmExportProbe {
    param([string]$Symbol, [string]$Year, [string]$ProbeDir, [int]$TimeoutMin = 20)

    Get-ChildItem $ProbeDir -File -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.File]::Delete($_.FullName) }

    $pd  = $ProbeDir.Replace([char]92, [char]47)
    $pc  = Join-Path $ProbeDir "probe_cmd.txt"
    "-data action=export symbols=$Symbol timeframe=M1 datefrom=$Year.01.01 dateto=$Year.12.31 timezone=Etc/UCT outputdir=$pd" |
        Set-Content -Path $pc -Encoding ASCII
    $log = Join-Path $ProbeDir "probe_$Symbol.log"
    $p = Start-Process -FilePath $QdmCli -ArgumentList "-run", ("file=" + $pc.Replace([char]92, [char]47)) `
         -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) {
        & taskkill /PID $p.Id /T /F 2>$null | Out-Null
        Write-Warning "  $Symbol : probe timed out after $TimeoutMin min"
    }

    $f = @(Get-ChildItem $ProbeDir -Filter *.csv -File -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $f) { return $null }
    $m = Measure-Shard $f.FullName
    return [pscustomobject]@{
        Rows    = $m.rows
        From    = $m.from
        To      = $m.to
        InRange = ($m.rows -gt 1 -and $m.from.Length -ge 4 -and $m.from.Substring(0,4) -eq $Year)
    }
}

function Invoke-Redownload {
    $want = @($Symbols -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    if ($want.Count -eq 0) {
        Write-Error "-Redownload requires -Symbols 'A,B,C'. There is deliberately no 'all': clearing every symbol would discard the entire store."
        Exit-Run 1
    }

    $registry = Get-QdmRegistrySymbols
    $unknown = @($want | Where-Object { $registry -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-Error "Not registered in QDM: $($unknown -join ', '). Clearing an unregistered symbol does nothing; check the spelling against '-symbol action=list'."
        Exit-Run 1
    }

    $histRootChk = Join-Path $QdmDir "user\data\History"

    if ($Resume) {
        # An interrupted refetch leaves the store partly filled: some symbols
        # complete, one mid-write, the rest still queued. `-data action=update`
        # picks up exactly what is missing, so resuming must NOT clear again -
        # a second clear would throw away the hours the first run did finish.
        Write-Host "`n=== REDOWNLOAD -Resume (non-destructive) ===" -ForegroundColor Cyan
        Write-Host " Symbols: $($want -join ', ')" -ForegroundColor Cyan
        Write-Host " Skipping the clear; re-running the fetch to complete what is missing." -ForegroundColor Cyan
        foreach ($sym in $want) {
            $t = Join-Path $histRootChk "$sym\$sym`_TICK.dat"
            $gb = if (Test-Path $t) { [math]::Round((Get-Item $t).Length / 1GB, 2) } else { 0 }
            Write-Host ("   {0,-8} holds {1} GB" -f $sym, $gb)
        }
    }
    else {
        Write-Host "`n=== REDOWNLOAD (destructive) ===" -ForegroundColor Yellow
        Write-Host " Symbols: $($want -join ', ')" -ForegroundColor Yellow
        Write-Host " This CLEARS each symbol's stored data, then re-fetches its full history." -ForegroundColor Yellow
        Write-Host " Whatever those symbols currently hold is discarded immediately; the refetch" -ForegroundColor Yellow
        Write-Host " takes hours per symbol and leaves them emptier than now if interrupted." -ForegroundColor Yellow
        Write-Host " (To finish an interrupted refetch instead, re-run with -Resume.)" -ForegroundColor Yellow
        if (-not $Force) {
            $ans = Read-Host " Type the number of symbols ($($want.Count)) to proceed"
            if ($ans -ne "$($want.Count)") { Write-Host "Aborted - nothing cleared."; Exit-Run 0 }
        }

        # ONE clear command per symbol. `-symbol action=clear symbols=A,B,C` accepts
        # a list (the CLI's own -h example shows one) but only ever clears the FIRST
        # symbol - it logs a single "Data cleared" and leaves the rest untouched.
        # Measured: a 9-symbol clear removed exactly one store. Passing a list here
        # silently turns a 9-symbol repair into a 1-symbol repair, and the update
        # that follows then looks like it ran fine.
        Write-Host "`nClearing $($want.Count) symbol(s), one command each..."
        Invoke-QdmSync -Lines @($want | ForEach-Object { "-symbol action=clear symbols=$_" })

        # Verify the stores actually went away rather than trusting the exit code.
        $notCleared = @($want | Where-Object { Test-Path (Join-Path $histRootChk "$_\$_`_TICK.dat") })
        if ($notCleared.Count -gt 0) {
            Write-Error "Clear did not remove the tick store for: $($notCleared -join ', '). Aborting before the refetch - continuing would silently repair only the symbols that did clear."
            Exit-Run 1
        }
        Write-Host "All $($want.Count) tick store(s) confirmed cleared."
    }

    Write-Host "`nRe-fetching full history (this is the long part)..."
    Invoke-QdmPhase -Lines @("-data action=update") -CompleteCheck $CheckUpdate `
                    -QuiesceSec $RedownloadQuiesceSec -TimeoutMin $RedownloadTimeoutMin -Phase "redownload" `
                    -ProgressPaths @($histRootChk)

    # --- clear stale derived-M1 datasets -------------------------------------
    # QDM stores ticks in <SYM>_TICK.dat and derives M1 at export time; a healthy
    # tick-sourced symbol has NO <SYM>_M1.dat at all (verified: 36 of 37 symbols
    # here). After a clear+refetch, an M1 export can leave behind a near-empty
    # <SYM>_M1.dat - and from then on QDM reads THAT instead of deriving from the
    # ticks, so every M1 export returns nothing in ~0.5 s while the ticks sit
    # untouched beside it. Measured on the NZDCAD pilot: with the file present,
    # 2020 exported 0 rows; with it moved aside, 372,673 rows.
    #
    # Only removed when a TICK store exists, so a symbol genuinely registered as
    # M1-only (where _M1.dat IS the data) is never touched.
    $histRoot = Join-Path $QdmDir "user\data\History"
    foreach ($sym in $want) {
        $symDir = Join-Path $histRoot $sym
        $m1  = Join-Path $symDir "$sym`_M1.dat"
        $tk  = Join-Path $symDir "$sym`_TICK.dat"
        if ((Test-Path $m1) -and (Test-Path $tk)) {
            $kb = [math]::Round((Get-Item $m1).Length / 1KB, 1)
            [System.IO.File]::Delete($m1)
            Write-Host "  removed stale derived-M1 dataset for $sym ($kb KB) - M1 now derives from ticks again"
        }
    }

    Write-Host "`n=== REDOWNLOAD: verifying local coverage by export probe ===" -ForegroundColor Cyan
    $probeDir = Join-Path $LogDir "redownload_probe"
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    $probeYear = if ($FullFromDate -ne "") { $FullFromDate.Substring(0,4) } else { "2011" }
    foreach ($sym in $want) {
        $r = Invoke-QdmExportProbe -Symbol $sym -Year $probeYear -ProbeDir $probeDir
        if ($null -eq $r)      { Write-Warning "  $sym : probe produced no file"; continue }
        if ($r.InRange)        { Write-Host "  OK  $sym : $probeYear now has $($r.Rows) bars ($($r.From) .. $($r.To))" -ForegroundColor Green }
        else                   { Write-Warning "  $sym : still no local data for $probeYear (nearest record $($r.From))" }
    }
    Write-Host "`nRe-run -Build to rebuild the affected warehouse shards." -ForegroundColor Cyan
}

if ($Redownload) { Invoke-Redownload; Exit-Run 0 }

# =============================================================================
# -Publish : send a consumer the shards it does not already have
#
# Manifest-diff over ssh: fetch the consumer's manifest, compare on
# (path, sha256), stream only the difference, verify it landed, and only then
# record it. The remote manifest is written from what actually VERIFIED, never
# from what was attempted - so an interrupted transfer resumes with the missing
# remainder instead of either resending everything or claiming success.
# =============================================================================

function Get-Consumers {
    $out = @()
    if (-not ($cfg.PSObject.Properties.Name -contains "Consumers")) { return $out }
    foreach ($p in $cfg.Consumers.PSObject.Properties) {
        if ($p.Name -like "_*") { continue }
        $c = $p.Value
        $out += [pscustomobject]@{
            Name       = $p.Name
            Host       = [string]$c.Host
            RemoteRoot = [string]$c.RemoteRoot
            Classes    = if ($c.PSObject.Properties.Name -contains "Classes")    { @($c.Classes) }    else { @("csv-shard") }
            Sources    = if ($c.PSObject.Properties.Name -contains "Sources")    { @($c.Sources) }    else { @() }
            Timeframes = if ($c.PSObject.Properties.Name -contains "Timeframes") { @($c.Timeframes) } else { @() }
            Clocks     = if ($c.PSObject.Properties.Name -contains "Clocks")     { @($c.Clocks) }     else { @() }
        }
    }
    return $out
}

function Publish-ToConsumer([object]$C) {
    Write-Host "`n=== PUBLISH -> $($C.Name)  ($($C.Host):$($C.RemoteRoot)) ===" -ForegroundColor Cyan

    $manifestPath = Join-Path $WhRoot "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        Write-Error "No warehouse manifest at $manifestPath - run -Build first."; Exit-Run 1
    }
    $local = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $mine = @($local.artifacts | Where-Object {
        ($C.Classes.Count    -eq 0 -or $C.Classes    -contains $_.class) -and
        ($C.Sources.Count    -eq 0 -or $C.Sources    -contains $_.source) -and
        ($C.Timeframes.Count -eq 0 -or $C.Timeframes -contains $_.tf) -and
        ($C.Clocks.Count     -eq 0 -or $C.Clocks     -contains $_.clock)
    })
    if ($mine.Count -eq 0) { Write-Warning "Nothing in the manifest matches $($C.Name)'s filters - nothing to publish."; return }

    # remote manifest (absent on a first publish)
    $remoteMap = @{}
    $remoteOther = @()
    $rawRemote = & ssh $C.Host "cat '$($C.RemoteRoot)/manifest.json' 2>/dev/null" 2>$null
    if ($LASTEXITCODE -eq 0 -and "$rawRemote".Trim() -ne "") {
        try {
            $rm = ($rawRemote -join "`n") | ConvertFrom-Json
            foreach ($a in @($rm.artifacts)) {
                $remoteMap[$a.path] = $a
                # "Ours to manage" is decided by the consumer's FILTERS, not by
                # presence in the local manifest. Using presence would carry a
                # retired artifact forward forever: dropped locally, still listed
                # remotely, and indistinguishable from another producer's entry.
                # Anything inside this consumer's (class, source, tf, clock) space
                # is ours to state the truth about - including by omission.
                $inOurSpace = (($C.Classes.Count    -eq 0 -or $C.Classes    -contains $a.class) -and
                               ($C.Sources.Count    -eq 0 -or $C.Sources    -contains $a.source) -and
                               ($C.Timeframes.Count -eq 0 -or $C.Timeframes -contains $a.tf) -and
                               ($C.Clocks.Count     -eq 0 -or $C.Clocks     -contains $a.clock))
                if (-not $inOurSpace) { $remoteOther += $a }
            }
        } catch { Write-Warning "Remote manifest unreadable - treating the consumer as empty." }
    }

    $need = @($mine | Where-Object {
        -not ($remoteMap.ContainsKey($_.path) -and $remoteMap[$_.path].sha256 -eq $_.sha256)
    })
    $currentAlready = @($mine | Where-Object { $need -notcontains $_ })

    Write-Host " matching artifacts: $($mine.Count) | already current there: $($currentAlready.Count) | to send: $($need.Count)"

    $verified = @()
    $failed   = @()
    $rr = $C.RemoteRoot      # needed by both branches - the manifest is written either way
    if ($need.Count -eq 0) {
        # Nothing to send, but still rewrite the remote manifest below: it may be
        # stale, BOM-corrupted or missing while the shards themselves are fine,
        # and that is exactly the state a consumer cannot recover from on its own.
        Write-Host " Consumer already holds every matching shard - refreshing its manifest."
    } else {

    $mb = [math]::Round((($need | Measure-Object bytes -Sum).Sum) / 1MB, 1)
    Write-Host " transferring $($need.Count) shard(s), $mb MB..."

    # tar stream through cmd: a PowerShell pipeline between two native commands
    # re-encodes the bytes and corrupts the archive. cmd passes them through.
    $listFile = Join-Path $env:TEMP "qdm_publish_list.txt"
    ($need | ForEach-Object { $_.path }) | Set-Content -Path $listFile -Encoding ASCII
    & ssh $C.Host "mkdir -p '$rr'" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Could not create $rr on $($C.Host)."; Exit-Run 1 }

    $tarCmd = "tar -cf - -C `"$WhRoot`" -T `"$listFile`" | ssh $($C.Host) `"tar -xf - -C '$rr'`""
    cmd /c $tarCmd
    if ($LASTEXITCODE -ne 0) { Write-Warning "Transfer reported exit code $LASTEXITCODE - verifying what actually landed." }

    # verify remotely, and record ONLY what verifies
    $sumFile = Join-Path $env:TEMP "qdm_publish_sums.txt"
    ($need | ForEach-Object { "$($_.sha256)  $($_.path)" }) | Set-Content -Path $sumFile -Encoding ASCII
    & scp -q $sumFile "$($C.Host):$rr/.publish-sums" | Out-Null
    $check = & ssh $C.Host "cd '$rr' && sha256sum -c .publish-sums 2>/dev/null; rm -f .publish-sums"
    Remove-Item $listFile, $sumFile -Force -ErrorAction SilentlyContinue
    $ok = @{}
    foreach ($line in $check) {
        if ($line -match '^(.*): OK$') { $ok[$Matches[1]] = $true }
    }
    $verified = @($need | Where-Object { $ok.ContainsKey($_.path) })
    $failed   = @($need | Where-Object { -not $ok.ContainsKey($_.path) })

    Write-Host " verified on the consumer: $($verified.Count) / $($need.Count)"
    foreach ($f in $failed) { Write-Warning "  NOT verified: $($f.path)" }

    }   # end of the transfer branch

    # remote manifest = what was already good + what just verified + anything of
    # theirs we do not manage. Never what we merely attempted.
    $final = @($remoteOther) + @($currentAlready) + @($verified)
    $outFile = Join-Path $env:TEMP "qdm_remote_manifest.json"
    Write-JsonFile ([pscustomobject]@{
        schema      = 1
        warehouse   = $env:COMPUTERNAME
        consumer    = $C.Name
        generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        clock       = $WhClock
        timezone    = $WhTimezone
        artifacts   = $final
    }) $outFile
    & scp -q $outFile "$($C.Host):$rr/manifest.json" | Out-Null
    $manifestOk = ($LASTEXITCODE -eq 0)

    Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    if (-not $manifestOk) {
        # Without a manifest the consumer cannot tell what it holds, and the next
        # publish would resend everything. Never report success on this path.
        Write-Error "Shards are in place on $($C.Name) but the manifest could not be written to $rr/manifest.json. Re-run -Publish once the path is writable."
        Exit-Run 1
    }
    if ($failed.Count -gt 0) {
        Write-Warning "$($failed.Count) shard(s) did not verify and were NOT recorded - re-run -Publish to retry just those."
    } else {
        Write-Host " Publish complete: $($final.Count) artifact(s) recorded on $($C.Name)." -ForegroundColor Green
    }
}

if ($Publish) {
    if ($WhRoot -eq "") { Write-Error "-Publish needs a Warehouse block in config.json."; Exit-Run 1 }
    $consumers = @(Get-Consumers)
    if ($Consumer -ne "") { $consumers = @($consumers | Where-Object { $_.Name -ieq $Consumer }) }
    if ($consumers.Count -eq 0) { Write-Error "-Publish: no matching consumer in config.json's Consumers block."; Exit-Run 1 }
    foreach ($c in $consumers) { Publish-ToConsumer $c }
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


# PHASE 1 - update all registered symbols
Invoke-QdmPhase -Lines @("-data action=update") -CompleteCheck $CheckUpdate `
                -QuiesceSec $UpdateQuiesceSec -TimeoutMin $UpdateTimeoutMin -Phase "update" `
                -ProgressPaths @((Join-Path $QdmDir "user\data\History"))

# common export bits

# Per-source export window: each source exports back
# as far as its BackfillWindowDays (which must exceed ProviderLagDays) so
# late-published provider data still falls inside the lookup before aging out.
function Get-FromArg([object]$Source, [int]$LookbackDays) {
    if ($Full) {
        return if ($FullFromDate -ne "") { "datefrom=$FullFromDate " } else { "" }
    }
    $days = if ($LookbackDays -gt 0) { $LookbackDays } else { $Source.BackfillWindowDays }
    if ($days -lt 1) { $days = $WindowDays }
    return "datefrom=" + (Get-Date).AddDays(-$days).ToString("yyyy.MM.dd") + " "
}

function Wait-TickFolderDrained { param([string]$Folder, [int]$MaxWaitMin = 0)
    if ($MaxWaitMin -le 0) { $MaxWaitMin = $DrainWaitMin }

    # a no-data export can never be consumed; drop it before it poisons the wait
    Remove-DatalessExports -Folder $Folder -MinAgeMin 2 | Out-Null

    $left = @(Get-ChildItem $Folder -Filter *.csv -File -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { return }

    # No terminal, no importer - waiting cannot change anything. Say so and move
    # on instead of burning the full timeout on this batch and every batch after
    # it (a closed MT5 used to cost MaxWaitMin per batch for the whole run).
    if (-not (Get-Process terminal64 -ErrorAction SilentlyContinue)) {
        Write-Warning "MT5 is not running - QdmImporter cannot consume the $($left.Count) file(s) in $Folder."
        Write-Warning "Not waiting. Start MT5 with the QdmImporter service enabled and they import on its next scan."
        # The drain wait is also the disk guard for tick seeds. Without a consumer
        # the remaining batches only add to the pile, so check before continuing.
        $freeNowGB = [math]::Round((Get-PSDrive $driveLetter).Free / 1GB, 1)
        if ($freeNowGB -lt $MinFreeSpaceGB) {
            Write-Error "Free space on ${driveLetter}: is $freeNowGB GB (below the configured $MinFreeSpaceGB GB) and nothing is draining the watch folder. Aborting before the remaining batches fill the disk."
            Exit-Run 1
        }
        return
    }

    $deadline = (Get-Date).AddMinutes($MaxWaitMin)
    while ((Get-Date) -lt $deadline) {
        Write-Host "  waiting for QdmImporter to consume $($left.Count) tick file(s) before next batch..."
        Start-Sleep -Seconds 60
        Remove-DatalessExports -Folder $Folder -MinAgeMin 2 | Out-Null
        $left = @(Get-ChildItem $Folder -Filter *.csv -File -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) { return }
    }

    Write-Warning "TICK folder not drained after $MaxWaitMin min - is the QdmImporter service running?"
    Write-Warning "Files still present (check the service's Experts log for why these are being skipped):"
    foreach ($f in $left) {
        $ageMin = [math]::Round(((Get-Date) - $f.LastWriteTime).TotalMinutes, 1)
        Write-Warning "  $($f.Name)  ($([math]::Round($f.Length/1MB,1)) MB, last written $ageMin min ago)"
    }
    Write-Warning "Continuing anyway - a persistently stuck file will cause this warning on every future batch until removed or fixed."
}

# =============================================================================
# PHASE 4+5 - reconcile MT5 coverage vs expected, auto-backfill genuine gaps
# (design notes: reconcile/backfill)
# QdmImporter writes, per custom symbol, a status file with the latest
# stored bar/tick time under the MT5 Common state dir. We compare that to
# "now - ProviderLagDays - margin" and re-export the missing range when behind.
# =============================================================================
function Resolve-StatusDir {
    if ($ReconcileStatusDir -ne "") { return $ReconcileStatusDir }
    # Default: alongside the watch root the service reads (Common\Files\QDM\status),
    # which the runner and the terminal already share - independent of terminal portability.
    return Join-Path $Mt5Common "status"
}

function Get-ExpectedCoverDate([object]$Source) {
    # newest date we expect MT5 to already hold, in the source's exported TZ
    $now = Get-Date
    $lag = $Source.ProviderLagDays
    $expected = $now.AddDays(-$lag)
    # compare at day granularity in the source timezone when known
    if ($Source.Timezone -ne "") {
        try {
            $tzi = [System.TimeZoneInfo]::FindSystemTimeZoneById($Source.Timezone)
            $expectedLocal = [System.TimeZoneInfo]::ConvertTime($now, $tzi)
            $expected = $expectedLocal.AddDays(-$lag)
        } catch { }
    }
    return $expected
}

function Get-SourceStatusFile([object]$Source, [string]$Custom) {
    $dir = Resolve-StatusDir
    return Join-Path $dir ("$Custom.json")
}

# Read a status file. Returns a hashtable {lastBar/lastTick (UTC datetime or null)}.
# Timestamps are Unix epoch seconds (as written by QdmImporter WriteStatus).
function Read-StatusFile([string]$Path) {
    $h = @{ lastBar = $null; lastTick = $null }
    if (-not (Test-Path $Path)) { return $h }
    try {
        $j = Get-Content $Path -Raw | ConvertFrom-Json
        foreach ($pair in @(@{k='lastBarTime';dst='lastBar'}, @{k='lastTickTime';dst='lastTick'})) {
            $v = $j.($pair.k)
            if ($null -ne $v -and "$v" -ne "" -and [long]$v -gt 0) {
                try { $h.($pair.dst) = [datetimeoffset]::FromUnixTimeSeconds([long]$v).LocalDateTime } catch { }
            }
        }
    } catch { }
    return $h
}

function Export-Range(
    [object]$Source,
    [string[]]$Symbols,
    [string]$Tf,                # "M1" or "TICK"
    [datetime]$FromDate         # start (inclusive); a recent gap, not full history
) {
    $tzArg = if ($Source.Timezone -ne "") { "timezone=$($Source.Timezone) " } else { "" }
    $frm = "datefrom=" + $FromDate.ToString("yyyy.MM.dd") + " "
    $fmt = if ($Tf -eq "TICK") { $tickFmt + " " } else { "" }
    if ($Tf -eq "TICK") {
        $outDir  = Join-Path $outTickRoot $Source.Name
        $outDirF = $outDir -replace '\\','/'
        for ($i = 0; $i -lt $Symbols.Count; $i += $TickBatchSize) {
            $batch = @($Symbols[$i..([Math]::Min($i + $TickBatchSize - 1, $Symbols.Count - 1))])
            $syms  = $batch -join ","
            Invoke-QdmPhase -Lines @("-data action=export symbols=$syms timeframe=TICK ${frm}${tzArg}$fmt outputdir=$outDirF") `
                            -CompleteCheck (New-ExportCheck -Expected $batch.Count) `
                            -QuiesceSec $ExportQuiesceSec -TimeoutMin $ExportTimeoutMin -Phase "backfill-tick-$($Source.Name)" `
                            -ProgressPaths @($outDir)
            Wait-TickFolderDrained -Folder $outDir
        }
    } else {
        $outDirLocal = Join-Path $outM1Root $Source.Name
        $outDir = $outDirLocal -replace '\\','/'
        $syms   = $Symbols -join ","
        Invoke-QdmPhase -Lines @("-data action=export symbols=$syms timeframe=M1 ${frm}${tzArg}outputdir=$outDir") `
                        -CompleteCheck (New-ExportCheck -Expected $Symbols.Count) `
                        -QuiesceSec $ExportQuiesceSec -TimeoutMin $ExportTimeoutMin -Phase "backfill-m1-$($Source.Name)" `
                        -ProgressPaths @($outDirLocal)
        Remove-DatalessExports -Folder $outDirLocal -MinAgeMin 2 | Out-Null
    }
}

function Invoke-Reconcile([object]$SourceList) {
    $reportDir = if ($ReconcileReportDir -ne "") { $ReconcileReportDir } else { $LogDir }
    New-Item -ItemType Directory -Force -Path (Resolve-StatusDir) | Out-Null
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $report = [collections.generic.list[object]]::new()
    $anyBackfill = $false

    Write-Host "`n=== RECONCILE (provider-lag aware) ===" -ForegroundColor Cyan
    foreach ($s in $SourceList) {
        $expected = Get-ExpectedCoverDate -Source $s
        $need = $expected.AddDays(-[double]$ReconcileMarginDays)

        # The main export phase has just re-exported the last BackfillWindowDays
        # for this source. A gap that starts inside that window was therefore
        # already covered by it, and re-exporting it is pure cost: a second full
        # phase plus a drain wait, usually for a range QDM has no data in - which
        # produces a CSV nothing can consume (see Remove-DatalessExports).
        $windowStart = (Get-Date).AddDays(-$s.BackfillWindowDays).Date

        foreach ($tf in @("M1","TICK")) {
            $syms = if ($tf -eq "M1") { $s.M1 } else { $s.Tick }
            if ($syms.Count -eq 0) { continue }

            # Collect the gaps first, then export once per distinct start date -
            # one phase (and one drain wait) instead of one per symbol. Symbols
            # almost always share a start date, so this is normally a single call.
            $gaps = @{}
            foreach ($sym in $syms) {
                $custom = "$sym`_$($s.Name)"
                $st = Read-StatusFile (Get-SourceStatusFile $s $custom)
                $last = if ($tf -eq "TICK") { $st.lastTick } else { $st.lastBar }
                if ($null -eq $last) {
                    Write-Warning "[$($s.Name)] $custom : no status file yet - cannot verify coverage (first run / service not upgraded?). Skipping backfill."
                    continue
                }
                if ($last -ge $need) { continue }       # current enough, no action

                # behind: classify severity
                $behindDays = [math]::Round(($expected - $last).TotalDays, 1)
                $severity = if ($behindDays -gt $s.BackfillWindowDays) { "aged-out" } else { "in-window" }

                # Start at the START of the day holding the last stored record,
                # not the day after it: that day is almost always partial (the
                # provider published the rest of it after the export ran), and
                # AddDays(1) skipped it entirely. Re-importing a day is safe -
                # bars merge, ticks replace exactly their covered window.
                $start = $last.Date
                $covered = ($start -ge $windowStart)

                Write-Host "  [$($s.Name)] $custom $tf behind by $behindDays d (severity: $severity)"
                $report.Add([pscustomobject]@{
                    Source = $s.Name; Symbol = $custom; Tf = $tf
                    Last   = $last.ToString("yyyy.MM.dd HH:mm:ss")
                    Expected = $expected.ToString("yyyy.MM.dd HH:mm:ss")
                    BehindDays = $behindDays; Severity = $severity
                    Action = if ($covered) { "covered-by-window" } else { "backfill-$(if($severity -eq 'aged-out'){'now'}else{'daily'})" }
                })

                if ($covered) {
                    Write-Host "     already inside this run's $($s.BackfillWindowDays)-day export window - no re-export"
                    continue
                }
                $key = $start.ToString("yyyy.MM.dd")
                if (-not $gaps.ContainsKey($key)) { $gaps[$key] = @() }
                $gaps[$key] += $sym
            }

            foreach ($key in ($gaps.Keys | Sort-Object)) {
                $batchSyms = @($gaps[$key])
                Write-Host "  -> backfilling $tf from $key for $($batchSyms.Count) symbol(s): $($batchSyms -join ', ')"
                Export-Range -Source $s -Symbols $batchSyms -Tf $tf `
                             -FromDate ([datetime]::ParseExact($key, "yyyy.MM.dd", $null))
                $anyBackfill = $true
            }
        }
    }

    if ($anyBackfill) {
        Write-Host "`n=== RECONCILE: re-reading status after backfill ===" -ForegroundColor Cyan
        # importer writes status asynchronously; give it a beat to consume the new files
        Start-Sleep -Seconds 90
        foreach ($s in $SourceList) {
            $expected = Get-ExpectedCoverDate -Source $s
            $need = $expected.AddDays(-[double]$ReconcileMarginDays)
            foreach ($tf in @("M1","TICK")) {
                $syms = if ($tf -eq "M1") { $s.M1 } else { $s.Tick }
                foreach ($sym in $syms) {
                    $custom = "$sym`_$($s.Name)"
                    $st = Read-StatusFile (Get-SourceStatusFile $s $custom)
                    $last = if ($tf -eq "TICK") { $st.lastTick } else { $st.lastBar }
                    if ($null -ne $last -and $last -ge $need) {
                        Write-Host "  OK  $custom ($tf) caught up to $($last.ToString('yyyy.MM.dd'))" -ForegroundColor Green
                    }
                }
            }
        }
    }

    $reportFile = Join-Path $reportDir "gaps_$stamp.json"
    $report | ConvertTo-Json -Depth 4 | Set-Content -Path $reportFile -Encoding UTF8
    if ($report.Count -gt 0) {
        $report | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $reportDir "gaps_latest.json") -Encoding UTF8
    }
    Write-Host "Reconcile report: $reportFile ($($report.Count) gap(s))"
}

# PHASE 2 + 3 - per-source exports
foreach ($s in $SourceList) {
    $tzArg = if ($s.Timezone -ne "") { "timezone=$($s.Timezone) " } else { "" }
    $winArg = Get-FromArg -Source $s -LookbackDays 0

    if ($s.M1.Count -gt 0) {
        $outDirLocal = Join-Path $outM1Root $s.Name
        $outDir = $outDirLocal -replace '\\','/'
        $syms   = $s.M1 -join ","
        Invoke-QdmPhase -Lines @("-data action=export symbols=$syms timeframe=M1 ${winArg}${tzArg}outputdir=$outDir") `
                        -CompleteCheck (New-ExportCheck -Expected $s.M1.Count) `
                        -QuiesceSec $ExportQuiesceSec -TimeoutMin $ExportTimeoutMin -Phase "export-m1-$($s.Name)" `
                        -ProgressPaths @($outDirLocal)
        Remove-DatalessExports -Folder $outDirLocal -MinAgeMin 2 | Out-Null
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
            Invoke-QdmPhase -Lines @("-data action=export symbols=$syms timeframe=TICK ${winArg}${tzArg}$tickFmt outputdir=$outDirF") `
                            -CompleteCheck (New-ExportCheck -Expected $batch.Count) `
                            -QuiesceSec $ExportQuiesceSec -TimeoutMin $ExportTimeoutMin -Phase "export-tick-$($s.Name)-b$batchNum" `
                            -ProgressPaths @($outDir)
            Wait-TickFolderDrained -Folder $outDir
        }
    }
}

# PHASE 4 + 5 - reconcile MT5 coverage and auto-backfill genuine gaps
if ($ReconcileEnabled) { Invoke-Reconcile -SourceList $SourceList }

$exported = @(Get-ChildItem $Mt5Common -Recurse -Filter "*.csv" |
              Where-Object { $_.DirectoryName -notmatch "\\done" }).Count
Write-Host "`nDone. $exported CSV file(s) currently waiting under $Mt5Common"
Write-Host "(imported files are handled per the service's InpDonePolicy)"

Exit-Run 0
