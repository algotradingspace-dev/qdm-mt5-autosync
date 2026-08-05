# Provider-lag handling & automatic backfill — design

**Status:** proposed (no code written)
**Date:** 2026-08-05
**Goal:** make the QDM→MT5 sync tolerant of *any* provider publishing data late, verify what actually landed in MT5, and automatically backfill the missing range — without ever needing a manual `-Full` to recover dropped data.

---

## 1. Problem statement

Today the pipeline is robust for the *update* side but fragile for the *export/import* side:

1. **`action=update` is a rolling, head-advancing download.** When a provider lags, QDM logs `No data for date` for the missing day and keeps going. The observed logs (darwinex) confirm this self-heals *within* the store: SP500 went missing for 08-01/08-02, then on 08-05 QDM wrote `2026.08.03`. The lag is transient and data eventually arrives in QDM's local store.
2. **The export window is a fixed `WindowDays` lookback** (`run_qdm_daily.ps1:406`; `datefrom = today - WindowDays`, default 7). `QdmImporter` merges into MT5 *only* what the exported CSV contains. That means:
   - If a provider lags **more than `WindowDays`**, by the time the data is published it has dropped out of the export lookback and is **never exported/imported again**.
   - Even a short lag creates a visible hole in MT5 for the lag window (the "0 bars/ticks from Aug 1" symptom), which is only re-filled if a later daily export happens to still cover those dates.
3. **No verification.** Nothing confirms MT5 actually received—and retained—a contiguous range per custom symbol. A failed import, a stuck folder, or a provider gap is only noticed by eyeballing MT5.

So the fix must (a) size the export/import coverage by *lag*, not by a fixed small window, and (b) detect and repair gaps generically for every source.

---

## 2. Key design decisions

### 2.1 Per-source lag allowance

Add two per-source config values:

- **`ProviderLagDays`** — the expected publication delay for that source (dukascopy ≈ 0, darwinex ≈ 2). Used only to decide what "a genuine gap" means. Data missing *within* `now − ProviderLagDays` is normal and is not alerted/repaired.
- **`BackfillWindowDays`** — the export/import lookback, **must be > max source `ProviderLagDays`** (recommend default 14, i.e. ~2× worst-case lag). `datefrom = today − BackfillWindowDays`.

Export+import is idempotent (`QdmImporter` merges/replaces in `[from,to]`), so widening the window is safe — it simply keeps a rolling span that comfortably exceeds lag, guaranteeing late-published data still falls inside an export before it can age out.

### 2.2 Source of truth for "what MT5 has"

Do **not** parse `.hcc`/`.tkc` binaries. The `QdmImporter` service is our code; extend it to emit a per-symbol status record after each import (`lastBarTime`, `lastTickTime`, last import time). The runner consumes these to detect gaps and measure recovered coverage. This is provider-agnostic — every source uses the same mechanism.

### 2.3 Repair by targeted re-export, not `-Full`

When a symbol is behind, run a small export from `MT5_last + 1day` → `now` for just that symbol (not the whole history), let the importer consume it, and re-verify. Repeated across runs until the gap closes. `-Full` stays reserved for genuine full reseeds.

---

## 3. Target run flow

```
0. Validate/register symbols                       (existing)
1. action=update                                   (existing, unchanged)
2. M1 export,  datefrom = today − BackfillWindowDays   [replaces WindowDays]
3. TICK export, datefrom = today − BackfillWindowDays   [replaces WindowDays]
4. Reconcile: read importer status → compare vs
   now − ProviderLagDays  → write gaps.json + warnings
5. Auto-backfill: for each behind symbol,
   export from MT5_last+1 → now (small batch),
   wait for importer, re-reconcile.                 [new, repeat across runs]
```

Steps 4–5 are opt-in via a `Reconcile` block in config; with it absent the pipeline behaves as today but with the widened window (step 2/3 still fixes darwinex).

---

## 4. Config changes (`config.json`)

### Per source
| Field | Purpose | Example |
|---|---|---|
| `ProviderLagDays` | Expected publication delay for alert/gap math | `{"darwinex": 2, "dukascopy": 0}` |
| `BackfillWindowDays` | Export/import lookback (overrides `WindowDays`) | `14` |

### Top-level `Reconcile` block (new)
```json
"Reconcile": {
  "_comment": "Verify MT5 coverage vs expected and auto-backfill gaps.",
  "Enabled": true,
  "StatusDir": "",
  "_StatusDir_comment": "Where the service writes per-symbol status. Empty = derive from Mt5Common\\..\\..\\Bases\\Custom.",
  "ExpectEndOfPreviousDay": true,
  "ReportPath": "",
  "_ReportPath_comment": "Path for gaps.json. Default logs\\gaps_<stamp>.json and gaps_latest.json."
}
```

---

## 5. QdmImporter changes

1. **Emit status** after each import (append/replace `<symbol>_<source>.json` or an upserted `status.csv` in a dedicated folder):
   ```
   symbol, source, tf, lastBarTime, lastTickTime, lastImportUtc, lastFile, rows_imported
   ```
2. **Report failure reasons** (skupped files, unparsed lines) in the same status so reconcile can see *why* a gap exists.

Status must be written when `InpDonePolicy=delete` too (today the ledger only appears for `=ledger`, a v1.42+ feature — see `docs/remote-data-source.md` Phase 1). Design the status writer to be independent of the done-policy.

---

## 6. Backfill algorithm (runner, PowerShell)

For each custom symbol `S` expected to be current:

```
expected_to   = now − ProviderLagDays(Source(S))         // inclusive
mt5_from, mt5_to = last stored range of S from status file
if mt5_to < expected_to:
    gap_days = expected_to − mt5_to
    log GAP: S behind by N day(s)   (rule out benign: only if gap_days > ProviderLagDays + margin)
    export S M1 and/or TICK, datefrom = mt5_to + 1day, date to now, timezone(cfg)
    wait for importer drain (reuse Wait-TickFolderDrained)
    re-read status, confirm mt5_to advanced
    if still behind across R runs -> persistent warning + gaps.json entry (no auto-alert yet)
```

Notes:
- Backfill exports use the same batching/drain logic already present (`TickBatchSize`, `Wait-TickFolderDrained`) so large tick fills don't stall.
- Re-run frequency: reconcile runs inside the daily job; a symbol that stays behind is simply retried next day until `BackfillWindowDays` rolls past it. No separate scheduler needed.
- Only run reconcile/backfill for sources present this run (`-OnlySource` scoping is honored).

---

## 7. Backward compatibility

- If `BackfillWindowDays` is absent, fall back to `WindowDays` (today's behaviour).
- If `ProviderLagDays` is absent, default 0 (a gap of any size is flagged).
- If `Reconcile.Enabled` is absent/false, steps 4–5 are skipped entirely; the only behavioural change is the widened export window, which is safe (idempotent merge).
- Status writer is additive; existing `InpDonePolicy` values behave exactly as before.

---

## 8. Gap severity model

| Condition | Classification | Action |
|---|---|---|
| `now − mt5_to ≤ ProviderLagDays` | normal (provider hasn't published) | none |
| `ProviderLagDays < now − mt5_to ≤ BackfillWindowDays` | transient gap, in-window | backfill this run |
| `now − mt5_to > BackfillWindowDays` | aged-out / genuine hole | backfill from `mt5_to+1`; log high-priority warning | 

No alert channel is wired yet — severity shows up as log warnings + `gaps.json` only.

---

## 9. Verification plan

1. **darwinex scenario (the original bug):** delete `202608.tkc` for `SP500_darwinex`; set `ProviderLagDays=2`, `BackfillWindowDays=14`; run sync. Confirm `SP500_darwinex` regains Aug data and gap closes, with status file updating.
2. **Synthetic aging:** temporarily set `mt5_to` in the status file 20 days behind. Confirm it's classified "aged-out" and backfilled.
3. **Wide-window no-op:** re-run twice; confirm no duplicate bars/ticks (merge idempotency).
4. **Opt-out:** set `Reconcile.Enabled=false`; confirm behaviour matches today apart from widened window.
5. **Multi-source:** confirm dukascopy (lag 0) and darwinex (lag 2) each reconcile under their own allowance.
6. **Scoping:** `-OnlySource darwinex` reconciles only darwinex symbols.

---

## 10. Open questions

1. **Aged-out window size.** `BackfillWindowDays=14` bounds how old data can be before it's "aged out." For genuinely long provider outages, do we want an even bigger window (e.g. 30) or is 14 acceptable given daily retries?
2. **Backfill cost.** Re-exporting full ticks for a large symbol covers a wide `[mt5_to+1 … now]`; acceptable daily, but confirm we never want to trigger it for symbols with multi-GB tick daily slices (bounded by `TickBatchSize`/drain).
3. **Status location.** Folder-based JSON vs single `status.csv` — need to confirm which is easiest for the service to update atomically and the runner to read reliably.
4. **Alerting.** Deliberately out of scope this round (your choice). Should the design reserve a hook (a `Notify-*` stub in the runner) so a channel can be added later without reshaping reconcile?