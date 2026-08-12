# QDM → MT5 AutoSync

**Automatically sync quality historical data from StrategyQuant's QuantDataManager into MetaTrader 5 custom symbols — daily, hands-free, no clicking.**

If you own [QuantDataManager](https://strategyquant.com/quantdatamanager/) you already have access to 20+ years of clean tick and M1 data for dozens of instruments. Getting it into MT5, however, normally means exporting symbols one by one in the GUI and manually importing each into a custom symbol — and the moment you finish, the data is already stale. QDM officially [cannot inject data into MT5 directly](https://strategyquant.com/doc/quantdatamanager/how-to-import-data-to-metatrader-5/); this project closes that gap.

After a one-time setup, the pipeline runs itself:

```
Windows Task Scheduler (any cadence)
  └─ qdm-mt5-autosync.ps1
       ├─ Phase 0: license refresh (brief GUI open/verify/close, so qdmcli never
       │            hits an expired local license file)
       ├─ Phase 1: qdmcli -data action=update      (incremental Dukascopy download)
       ├─ Phase 2: qdmcli -data action=export      (rolling backfill CSV window)
       ├─ Phase 3: per-source tick export batches
       ├─ Phase 4: reconcile MT5 coverage per symbol (provider-lag aware)
       └─ Phase 5: auto-backfill the missing range for any symbol that's behind
            └─ %APPDATA%\MetaQuotes\Terminal\Common\Files\QDM\{M1,TICK}\*.csv
                 └─ QdmImporter (MQL5 Service inside MT5)
                      ├─ creates custom symbols automatically, cloned from
                      │  your broker's specs (digits, contract size, sessions)
                      ├─ merges bars via CustomRatesUpdate  → idempotent
                      ├─ replaces tick windows via CustomTicksReplace
                      ├─ writes per-symbol status files (last stored bar/tick)
                      └─ archives processed CSVs to done\
```

Your EAs then backtest against `EURUSD.QDM`, `XAUUSD.QDM`, etc. — always current as of yesterday, with real Dukascopy ticks where you want them.

## What's in the box

| File | Runs where | Job |
|---|---|---|
| `qdm-mt5-autosync.ps1` | PowerShell / Task Scheduler | Pure runner. Reads `config.json`, drives qdmcli: refreshes the QDM license via a brief GUI open, updates QDM's data store, exports CSVs into MT5's Common Files folder. |
| `config.json` | (you create this, from `config.example.json`) | Every setting: QDM path, symbol lists, history depth, watchdog tuning. The only file you ever edit. |
| `QdmImporter.mq5` | MT5 (as a **Service**) | Watches the folder, auto-creates custom symbols, imports bars/ticks. Owns *what gets imported*, via its own compiled inputs. |

The split is deliberate: `config.json` + the PowerShell runner fetch and organize everything you list; the service's own inputs (`InpImportM1`, `InpImportTicks`, `InpSymbolFilter`) decide per-terminal what actually lands in MT5. Several terminals on one machine can share one export and each import a different subset — no PowerShell edits needed either way, ever, after initial setup.

## Requirements

- Windows 10/11 with QuantDataManager **Build 119+** (the build that ships `qdmcli.exe`; developed against Build 124)
- MetaTrader 5
- Historical data already registered in QDM (symbols added via GUI or via this script's `-Setup`)

## Quick start

**1. MT5 side.** Copy `QdmImporter.mq5` to `<MT5 data folder>\MQL5\Services\` (MetaEditor → File → Open Data Folder). Compile (F7, expect 0 errors), then in MT5: Navigator → Services → right-click QdmImporter → **Add Service** → enable. It starts with the terminal and survives restarts.

> Compile first, start second — recompiling a *running* service silently stops it.

**2. PowerShell side.** Clone/copy this repo somewhere permanent (the examples below use `<repo>` as a placeholder for its full path). Copy `config.example.json` → `config.json` in that same folder and edit it: your QDM install path, your symbol lists (`M1Symbols`, `TickSymbols` — names must match `qdmcli -symbol action=list` **exactly**), and `FullFromDate` for how deep the initial seed should go. `qdm-mt5-autosync.ps1` itself needs no edits — it reads everything from `config.json`, and refuses to run with a clear error if the file is missing or malformed.

**3. Register symbols** (skip for symbols already in your QDM):

```powershell
powershell -ExecutionPolicy Bypass -File <repo>\qdm-mt5-autosync.ps1 -Setup
```

**4. Seed the history** (run in the evening; a multi-symbol seed with tick data works well into the night):

```powershell
powershell -ExecutionPolicy Bypass -File <repo>\qdm-mt5-autosync.ps1 -Full
```

**5. Schedule the sync.** From an elevated PowerShell prompt (any cadence you like — daily, weekly, twice a day):

```powershell
schtasks /Create /TN "QDM-MT5-AutoSync" /TR "powershell -ExecutionPolicy Bypass -File <repo>\qdm-mt5-autosync.ps1" /SC DAILY /ST 09:00 /RL HIGHEST /F
```

Pick a time after Dukascopy publishes the previous day's data — 09:00 in your local timezone is safe. A few variations:

```powershell
# Weekly instead of daily (e.g. Sunday evening, to catch up the whole week)
schtasks /Create /TN "QDM-MT5-WeeklySync" /TR "powershell -ExecutionPolicy Bypass -File <repo>\qdm-mt5-autosync.ps1" /SC WEEKLY /D SUN /ST 20:00 /RL HIGHEST /F

# Twice a day (morning + evening) - two separate tasks, same command
schtasks /Create /TN "QDM-MT5-Sync-AM" /TR "powershell -ExecutionPolicy Bypass -File <repo>\qdm-mt5-autosync.ps1" /SC DAILY /ST 09:00 /RL HIGHEST /F
schtasks /Create /TN "QDM-MT5-Sync-PM" /TR "powershell -ExecutionPolicy Bypass -File <repo>\qdm-mt5-autosync.ps1" /SC DAILY /ST 21:00 /RL HIGHEST /F

# Trigger a run manually, any time
schtasks /Run /TN "QDM-MT5-AutoSync"

# Check it's registered and see next run time
schtasks /Query /TN "QDM-MT5-AutoSync" /V /FO LIST

# Remove it
schtasks /Delete /TN "QDM-MT5-AutoSync" /F
```

`/RL HIGHEST` runs it elevated (needed for reliable process control); it runs under your own user account by default and only while you're logged in. For a machine that stays logged in as a dedicated trading user (VPS-style), that's normal and sufficient — no need for `/RU`/`/RP` service-account flags unless you specifically run headless without any interactive session.

**6. Verify.** MT5 Toolbox → Experts tab shows lines like `[QdmImporter] OK EURUSD-M1-No Session.csv -> EURUSD.QDM (M1)`. Symbols appear under `Custom\QDM`. Check bar/tick ranges in the Symbols dialog (set the date range to your seed depth, not the default last-day window).

## config.json reference

| Field | Meaning |
|---|---|
| `QdmDir` | QuantDataManager install folder (must contain `qdmcli.exe`) |
| `Mt5CommonOverride` | Leave `""` to auto-use `%APPDATA%\MetaQuotes\Terminal\Common\Files\QDM`; set only for non-standard MT5 installs |
| `WindowDays` | Rolling export window for daily runs (days). A per-source `BackfillWindowDays` overrides it. |
| `FullFromDate` | History depth for `-Full` runs, `yyyy.MM.dd`; empty = everything QDM has |
| `Sources` | Map of QDM data source → symbol lists. Each source (e.g. `dukascopy`, `darwinex`, `crypto`, `yahoo`) carries its own `Timezone`, `ProviderLagDays`, `BackfillWindowDays`, `M1Symbols`, and `TickSymbols`. Symbols missing from your QDM registry are **auto-registered** under their source (full history downloads during the next update phase); names the source doesn't offer fail registration and are dropped with a warning. |
| `Sources.<name>.Timezone` | Applied at export time via the CLI `timezone=` parameter. Empty = source-native (UTC for Dukascopy). List valid names with `qdmcli.exe -data action=timezones`; `EETUS` = UTC+2 with US DST, the typical MT5 broker time. |
| `Sources.<name>.ProviderLagDays` | Expected publication delay for that source (dukascopy 0, darwinex 2). Data missing within `now − lag` is normal; anything beyond that is flagged/repaired. |
| `Sources.<name>.BackfillWindowDays` | How far each source's exports look back (default 14). Keep it > `ProviderLagDays` so late-published provider data still lands inside the export window before it ages out. |
| `Reconcile` | (Optional) block toggling coverage verification + auto-backfill: `Enabled`, `StatusDir`, `ProviderLagDays`, `MarginDays`, `ReportDir`. When absent, the pipeline runs as before but exports use `BackfillWindowDays`. |
| `LicenseRefresh` | (Optional) block toggling the pre-run GUI license refresh: `Enabled` (default true), `WaitSec` (how long to wait for the GUI to reach "Pro version", default 90), `SettleSec` (extra seconds to leave the GUI open, default 10). Disable if you manage the QDM license manually, or skip per-run with `-NoLicenseRefresh`. |
| `TickBatchSize` | Tick exports run in sequential batches of this many symbols (default 3). Bounds peak disk usage and avoids QDM silently dropping a job for a symbol already busy in another job. Between batches the script waits for the importer to drain the source's TICK folder. |
| `MinFreeSpaceGB` | `-Full` runs abort below this free space on the MT5 Common drive (full-history tick CSVs are 5–20 GB per symbol) |
| `Watchdog.*` | Fallback-only timing; defaults are sane, only tune if you see `FALLBACK STOP` warnings |

**Multi-source naming.** Exports land in per-source subfolders (`M1\dukascopy\`, `TICK\darwinex\`, …) and the service derives the custom symbol name from the folder: `EURUSD_dukascopy`, `WS30_darwinex`, grouped in the MT5 symbol tree under `Custom\QDM\<source>`. This lets you keep the same instrument from two sources side by side (e.g. `EURUSD_dukascopy` vs `EURUSD_darwinex`) and pick per-backtest. Files placed directly in `M1\`/`TICK\` (no source folder) keep the classic `EURUSD.QDM` naming for backward compatibility.

A note on QDM/SQX **broker profiles**: they configure broker timezone plus broker-specific instrument settings (point value, tick step, sessions, default spread/slippage) so *StrategyQuant backtests* match your broker — none of that is embedded in exported price data. This pipeline instead clones contract specs from your broker's live MT5 symbol, which serves the same purpose on the MT5 side; the only profile aspect relevant here is timezone, handled by `Sources.<name>.Timezone`.

`WorkDir` isn't in the config on purpose — the script always uses its own folder (`$PSScriptRoot`), so `config.json`, `logs/`, and the script travel together wherever you clone the repo.

## Service inputs

| Input | Default | Meaning |
|---|---|---|
| `InpUseCommonFolder` | `true` | which sandbox to watch: `true` = the shared `Common\Files` tree, `false` = **this terminal's own** `MQL5\Files`. Set `false` on a remote or containerised terminal, where the machine delivering the CSVs cannot reach the Common folder. Every file operation follows this flag. |
| `InpWatchDir` | `QDM` | folder inside the chosen sandbox (must match the PS script's `$Mt5Common` leaf when using Common) |
| `InpImportM1` / `InpImportTicks` | `true` | consume bar / tick exports |
| `InpSymbolFilter` | `""` | csv of base symbols to import; empty = all |
| `InpSourceFilter` | `""` | csv of **source folders** to import (`dukascopy`); empty = all. Lets several terminals share one delivered watch tree and each take only its own slice, with no per-terminal copy of the CSVs. |
| `InpCustomPostfix` | `.QDM` | custom symbol naming — **legacy fallback only**, for files with no source subfolder. Avoid: a `.QDM` suffix collides with the broker's own symbol name in downstream tooling. Source-tagged naming (`EURUSD_dukascopy`) is the supported path. |
| `InpBrokerSuffixes` | `,.a,.r,m,…` | suffix candidates for finding the broker symbol to clone specs from |
| `InpDonePolicy` | `move` | `move` / `delete` / `keep` processed files |
| `InpStatusDir` | `status` | subfolder under the watch dir where per-symbol coverage status (`<custom>.json`) is written — read by the runner's reconcile pass to auto-backfill gaps, and by remote consumers. Empty disables it. |
| `InpClockTag` | `""` | the timezone the CSVs were exported in (`utc` \| `eetus` \| `eet`), recorded into every status file so a consumer can never misread the bars. Leave empty only if nothing downstream reads the data. |
| `InpScanMinutes` | `15` | folder scan interval |

## Serving other machines (warehouse mode)

The split above also works across hosts: this machine keeps the QDM licence and
does all the fetching, and other MT5 estates consume what it produces. The
service is deliberately portable — `InpUseCommonFolder=false` points it at the
terminal's own `MQL5\Files`, `InpSourceFilter` lets each terminal take only the
sources it should hold, and `InpClockTag` stamps the export timezone into the
status files so no consumer has to guess.

`-Build` produces the consumable artifacts — one CSV per symbol per year under
`<Root>/<source>/<clock>/<SYMBOL>/M1/`, plus a `manifest.json` carrying a sha256
per shard so a consumer diffs instead of re-transferring:

```bash
powershell -ExecutionPolicy Bypass -File qdm-mt5-autosync.ps1 -Build
```

It is resumable — shards already recorded in the manifest are skipped without
launching qdmcli, and only the current year is rebuilt on every run. Scope a
partial build with `-OnlySource`, `-OnlySymbols`, `-BuildFromYear`,
`-BuildToYear`. Configure it via the `Warehouse` block in `config.json`.

The clock is deliberately UTC (`Etc/UCT`), not the `EETUS` used for MT5 custom
symbols: these shards feed consumers that must never route bars through a broker
wall-clock table. The clock is part of the shard path, so it cannot be lost.

`-Publish` sends a consumer host only the shards it doesn't already have:

```bash
powershell -ExecutionPolicy Bypass -File qdm-mt5-autosync.ps1 -Publish
```

It diffs the consumer's manifest on `(path, sha256)`, streams the difference over
`ssh`+`tar`, verifies it remotely with `sha256sum`, and records **only what
verified** — so an interrupted transfer resumes with the remainder instead of
resending everything or reporting a success that didn't happen. Configure hosts
in the `Consumers` block; target one with `-Publish -Consumer <name>`. It never
touches QDM, so it skips the licence refresh and runs happily with the GUI open.

## Design notes & data facts

**M1 for everything, ticks for the few.** MT5 computes all higher timeframes from M1, and "Every tick based on real 1-minute" covers most backtesting needs. Full tick history runs 10–20 GB *per symbol*; reserve it for symbols you genuinely test in real-tick mode. MT5 **cannot** build higher timeframes from tick data alone — M1 must always be imported alongside.

**Idempotent by construction.** Bar imports merge; tick imports replace exactly the window each file covers. Overlapping exports, re-runs, and missed days that later backfill are all safe.

**Providers can publish late — handled.** Some sources (e.g. darwinex) can lag a day or two, so a given calendar day may only appear in QDM's store later. The exported window is per-source (`BackfillWindowDays`, default 14) and `QdmImporter` writes per-symbol status so the runner's reconcile pass compares what MT5 actually holds against `now − ProviderLagDays` and re-exports the missing range for any behind symbol. A genuine gap self-heals on the next run instead of aging out of a fixed 7-day window.

**Async CLI, handled.** `qdmcli` dispatches `-data` jobs asynchronously — a naive script with `-exit` in the command file kills the jobs before they run (a several-hour update "finishes" in one second). This script launches phases without `-exit` and detects completion via process self-exit and log markers, with a long disk-quiescence window only as a warned fallback.

**Timezone.** QDM serves Dukascopy data in UTC. If you need broker-timezone-aligned bars (typically UTC+2/+3 with US DST), create a clone in QDM with the shifted timezone and export the clone instead.

## Troubleshooting

**`FALLBACK STOP` warning killed a running export (older versions).** NTFS updates directory-listed file sizes *lazily* for files a writer holds open — a healthy multi-GB export can show frozen file sizes for hours. Current versions therefore monitor the qdmcli **log file through an open handle** (every active job appends progress lines), which cannot false-freeze. If you still see a fallback stop, the phase genuinely stalled — check the phase log.

**Disk filling up during a big seed.** Tick CSVs are 5–20 GB per symbol. Three mitigations are built in: tick exports run in small batches (`TickBatchSize`), the script waits for the importer to drain the TICK folder between batches, and the service's default `InpDonePolicy` is `delete` (set `move` only if you want an archive in `done\` and have the space). `-Full` also refuses to start below `MinFreeSpaceGB`.

**"config.json not found" / validation errors.** The script refuses to guess — copy `config.example.json` to `config.json` in the same folder and fill in the required fields. It also checks `QdmDir` actually exists and contains `qdmcli.exe`, and that `M1Symbols` isn't empty, before doing anything else.

**Service logs nothing.** It prints its resolved watch path and a heartbeat every cycle — if even the heartbeat is missing, the service isn't running (most common cause: recompiling stopped it). If the heartbeat says "no importable files found", the export side hasn't delivered — check the phase logs in `logs\`.

**"Another instance of QuantDataManager is running."** QDM is single-instance per installation. The script auto-kills stale `qdmcli` leftovers but deliberately refuses to kill an open QDM GUI — close it and re-run.

**Tick CSV full of `0.00000` prices.** You exported `timeframe=TICK` without naming a tick format; the CLI's default is a *bar* format. The script always passes `format="Generic tick format (comma delimited)"` — keep that if you customize.

**Tick export produces no files at all, no error.** QDM silently drops an export job for a symbol that's already busy in another export job — so dispatching M1 and TICK exports in the same qdmcli session makes the TICK jobs for overlapping symbols vanish without any error message. The script therefore runs them as separate sequential phases (`export-m1`, then `export-tick`); keep that structure if you customize.

**`0 bars merged` for one symbol.** Usually a race: the service read the CSV while QDM was still writing it. Current versions guard against this (a file must be non-empty and size-stable over 2 s before import), so a file caught mid-write is simply retried next cycle. If it repeats for the same symbol across runs, inspect its CSV in the watch folder: zero bytes = QDM-side export issue, content present = open an issue with the first 3 lines.

**Legacy `.QDM` symbols left over from before source-tagged naming.** Retire
them: a `.QDM` suffix is *stripped* by downstream tooling that normalises broker
symbol names (a dot-separated 1–6 letter suffix is treated as a broker feed
marker), so `EURUSD.QDM` normalises to `EURUSD` and becomes indistinguishable
from your broker's own symbol — which is how QDM bars end up silently answering a
request meant for broker data. Source-tagged names (`EURUSD_dukascopy`) are safe;
an underscore is not a stripped separator. `QdmCleanup.mq5` with
`InpLegacyOnly=true` deletes only the legacy family, leaving the source-tagged
symbols alone (run with `InpDryRun=true` first). MT5 must be running — deleting
the folders on disk leaves the symbols registered in `Bases\symbols.custom.dat`.

**Garbage symbol named like a date (e.g. `20260722.QDM`).** Caused by moving an archived file from `done\` back into a watch folder in very old versions; current versions reject date-stamp filenames. Never recycle `done\` files — re-export instead.

**Symbol created "with defaults (no broker origin found)".** The service couldn't find a broker symbol matching the base name to clone specs from — add your broker's suffix to `InpBrokerSuffixes`, delete the defaults-based symbol, and let it recreate.

**Deleting a custom symbol fails.** Remove it from Market Watch first (right-click → Hide), then delete in the Symbols dialog.

**Duplicate `EURUSD(2)`-style symbols in QDM.** You ran `-Setup` for symbols that already existed. Run `-Cleanup`; it lists all `(n)` duplicates and deletes after confirmation.

**Index CFDs (DAX, NDX, SP500…).** Contract specs differ meaningfully between brokers — after first import, verify contract size/tick value in the symbol specification against the broker you actually trade them with.

## QDM license expiry (added 2026-08)

**Why it matters.** QDM validates a locally-stored license file at every startup. The headless CLI (`qdmcli`) only *reads* that file — it can never refresh it — while the **GUI re-verifies online on every launch**. If the GUI isn't opened for a long stretch, the license file's validation window lapses and every CLI phase fails within seconds with `Missing license. / Exit app - Missing license.` (the underlying error is `License file validation has expired.`). The sync then "finishes" suspiciously fast with hours of 15-second no-ops, and no data lands in MT5.

**What this repo does about it (all merged into `qdm-mt5-autosync.ps1`, no separate script/task):**

1. **Pre-run license refresh (default on).** Before any `qdmcli` phase, the runner opens the QDM GUI, waits until it re-verifies online (window title reaches `Pro version`), then closes it again. This keeps the local license file fresh on *every* run — there's no harm in a brief GUI open/close, and it guarantees the headless CLI below never trips over an expired file. Tune or disable via the `LicenseRefresh` config block, or skip per-run with `-NoLicenseRefresh`.

2. **Early, loud detection.** Every `qdmcli` phase still scans its log for the license-failure markers (`Missing license` / `License file validation has expired`) and aborts the run with a clear `QDM LICENSE FAILURE` message instead of silently no-op'ing — a safety net in case the refresh was skipped or the server itself is down.

**If a run fails with the license error anyway** (e.g. after a long outage or if the refresh was disabled): open the QDM GUI once and confirm it shows the instrument lists / `Pro version`, close it, then re-run:

```powershell
schtasks /Run /TN "QDM-MT5-AutoSync"
```

## Disclaimer

This is a community tool, not affiliated with StrategyQuant or MetaQuotes. Historical data quality and licensing are governed by your QuantDataManager subscription. Backtest results depend on data and modelling assumptions — always validate before trading real money.

## License

MIT — use it, fork it, ship it. If it saves you the one-by-one clicking marathon it was built to kill, a star is appreciated.

*Built for the algorithmic-trading community — data tooling, EA development, and education.*
