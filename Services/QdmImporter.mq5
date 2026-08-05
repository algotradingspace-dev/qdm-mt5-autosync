//+------------------------------------------------------------------+
//|                                                  QdmImporter.mq5 |
//|                          Algo Trading Space - QDM -> MT5 Bridge  |
//|                                                                  |
//| MQL5 SERVICE (not an EA). Install to: MQL5\Services\             |
//| Watches Common\Files\QDM\ for CSV exports produced by qdmcli.exe |
//| and imports them into MT5 custom symbols automatically:          |
//|   - Creates the custom symbol if missing (cloned from broker     |
//|     symbol specs -> digits, tick size, contract size, sessions)  |
//|   - Bars  : CustomRatesUpdate()  -> merge, idempotent            |
//|   - Ticks : CustomTicksReplace() -> per covered window           |
//|   - Moves processed files to QDM\done\ (or deletes them)         |
//|                                                                  |
//| Expected file naming (produced by run_qdm_daily.ps1):            |
//|   <BASE>_<TF>.csv      e.g. EURUSD_M1.csv, GBPUSD_TICK.csv       |
//|   QDM symbol postfixes are handled: EURUSD_M1_M1.csv also works, |
//|   base symbol = leading A-Z0-9 token, TF = last known TF token.  |
//|                                                                  |
//| Supported CSV layouts (auto-detected, comma or tab delimited):   |
//|   Bars : DateTime,O,H,L,C[,TickVol[,Vol[,Spread]]]               |
//|          Date,Time,O,H,L,C[,TickVol[,Vol[,Spread]]]              |
//|   Ticks: DateTime[.ms],Bid,Ask[,Last[,Vol]]                      |
//| Header lines are skipped automatically.                          |
//+------------------------------------------------------------------+
#property service
#property copyright "Algo Trading Space"
#property version   "1.42"
#property strict

//--- === IMPORT SETTINGS ===
input string InpWatchDir        = "QDM";      // Watch folder (inside Common\Files)
input bool   InpImportM1        = true;       // Import M1 bar data
input bool   InpImportTicks     = true;       // Import tick data
input string InpSymbolFilter    = "";         // Import only these base symbols (csv, empty = all)
input string InpDonePolicy      = "delete";   // After import: delete | move | keep (move archives to done\, heavy for tick seeds)
input int    InpScanMinutes     = 15;         // Folder scan interval (minutes)
input int    InpChunkBars       = 200000;     // Bars per CustomRatesUpdate call
input int    InpChunkTicks      = 500000;     // Ticks per CustomTicksReplace call

//--- === COVERAGE STATUS (reconcile/backfill, see docs/data-gap-backfill.md) ===
input string InpStatusDir       = "status";   // Status subfolder under InpWatchDir (empty = disabled); run_qdm_daily.ps1 reads it to detect/backfill gaps

//--- === SYMBOL SETTINGS ===
input string InpCustomPostfix   = ".QDM";     // LEGACY fallback only - naming for files with no source subfolder (unused with a Sources-based config.json)
input string InpCustomPath      = "Custom\\QDM"; // Custom symbol tree path
input string InpBrokerSuffixes  = ",.a,.r,m,.pro,.raw,+,c"; // Origin suffix candidates (csv, first match wins; leading empty = no suffix)
input int    InpFixedSpreadPts  = 0;          // Fixed spread override, points (0 = keep origin)

//--- === LOGGING ===
input bool   InpVerbose         = true;       // Verbose per-file logging

//--- known timeframe tokens in filenames
string g_TfTokens[] = {"TICK","M1","M5","M15","M30","H1","H4","D1"};
string g_Filter[];                             // parsed InpSymbolFilter

//+------------------------------------------------------------------+
//| Service entry point                                              |
//+------------------------------------------------------------------+
void OnStart()
  {
   // parse symbol filter once
   ArrayResize(g_Filter, 0);
   if(StringLen(InpSymbolFilter) > 0)
     {
      string f = InpSymbolFilter;
      StringToUpper(f);
      StringReplace(f, " ", "");
      StringSplit(f, ',', g_Filter);
     }

   string fullPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + InpWatchDir;
   PrintFormat("[QdmImporter] service started. Watch folder: %s | M1=%s Ticks=%s Filter=%s | scan every %d min",
               fullPath,
               InpImportM1 ? "on" : "off",
               InpImportTicks ? "on" : "off",
               (ArraySize(g_Filter) == 0) ? "all" : InpSymbolFilter,
               InpScanMinutes);

   while(!IsStopped())
     {
      int processed = ScanAndImport();
      if(processed > 0)
         PrintFormat("[QdmImporter] cycle done, %d file(s) imported", processed);
      else if(InpVerbose)
         Print("[QdmImporter] scan cycle: no importable files found");

      // sleep in small slices so the service stops promptly
      int slices = InpScanMinutes * 12;                 // 5s slices
      for(int i = 0; i < slices && !IsStopped(); i++)
         Sleep(5000);
     }
   Print("[QdmImporter] service stopped");
  }

//+------------------------------------------------------------------+
//| Scan watch folder, import every CSV found                        |
//+------------------------------------------------------------------+
int ScanAndImport()
  {
   int count = 0;
   count += ScanFolder(InpWatchDir, "", "");                // legacy root files, TF from filename
   if(InpImportM1)
      count += ScanTypeDir("M1");
   if(InpImportTicks)
      count += ScanTypeDir("TICK");
   return count;
  }

//+------------------------------------------------------------------+
//| Scan M1\ or TICK\: files directly inside (untagged) plus every   |
//| per-source subfolder (folder name becomes the source tag, used   |
//| in the custom symbol name: EURUSD_dukascopy, WS30_darwinex)      |
//+------------------------------------------------------------------+
int ScanTypeDir(const string tfTag)
  {
   string root  = InpWatchDir + "\\" + tfTag;
   int    count = ScanFolder(root, tfTag, "");              // untagged files in the type root
   string entry;
   long   handle = FileFindFirst(root + "\\*", entry, FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return count;
   string subs[];
   do
     {
      int len = StringLen(entry);
      if(len > 1 && StringGetCharacter(entry, len - 1) == '\\')
        {
         int n = ArraySize(subs);
         ArrayResize(subs, n + 1);
         subs[n] = StringSubstr(entry, 0, len - 1);
        }
     }
   while(FileFindNext(handle, entry));
   FileFindClose(handle);

   for(int i = 0; i < ArraySize(subs); i++)
      count += ScanFolder(root + "\\" + subs[i], tfTag, subs[i]);
   return count;
  }

//+------------------------------------------------------------------+
//| Scan one folder; forceTf overrides filename TF detection,        |
//| srcTag ("" = none) becomes the custom symbol name suffix         |
//+------------------------------------------------------------------+
int ScanFolder(const string dir, const string forceTf, const string srcTag)
  {
   int    count = 0;
   string fname;
   string mask   = dir + "\\*.csv";
   long   handle = FileFindFirst(mask, fname, FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return 0;

   string files[];
   do
     {
      int n = ArraySize(files);
      ArrayResize(files, n + 1);
      files[n] = fname;
     }
   while(FileFindNext(handle, fname));
   FileFindClose(handle);

   for(int i = 0; i < ArraySize(files); i++)
     {
      string path = dir + "\\" + files[i];
      if(!IsFileStable(path))
        {
         if(InpVerbose)
            PrintFormat("[QdmImporter] %s still being written (or empty) - will retry next cycle", files[i]);
         continue;
        }
      if(ImportFile(path, files[i], forceTf, srcTag))
        {
         count++;
         FinishFile(path, files[i], forceTf, srcTag);
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| A file is importable only if non-empty and not written to for    |
//| 60 s. QDM writes exports in bursts with multi-second pauses, so  |
//| a short size-stability window can false-pass mid-export; the     |
//| modification-time cool-down cannot.                              |
//+------------------------------------------------------------------+
bool IsFileStable(const string path)
  {
   long sz = FileGetInteger(path, FILE_SIZE, true);
   if(sz <= 0)
      return false;                                   // missing or empty
   datetime mod = (datetime)FileGetInteger(path, FILE_MODIFY_DATE, true);
   if(mod <= 0)
      return false;
   if(TimeLocal() - mod < 60)
      return false;                                   // written within last 60 s -> still hot
   return true;
  }

//+------------------------------------------------------------------+
//| Import one CSV file                                              |
//+------------------------------------------------------------------+
bool ImportFile(const string path, const string fname, const string forceTf, const string srcTag)
  {
   string base, tf;
   if(!ParseFileName(fname, base, tf))
     {
      PrintFormat("[QdmImporter] SKIP %s: cannot derive symbol/timeframe from name", fname);
      return false;
     }
   if(forceTf != "")
      tf = forceTf;      // folder placement overrides filename detection

   // import-control gates: skipped files stay in place, untouched
   if(tf == "TICK" && !InpImportTicks)
      return false;
   if(tf != "TICK" && !InpImportM1)
      return false;
   if(!SymbolAllowed(base))
      return false;

   // source-tagged naming: EURUSD_dukascopy, WS30_darwinex; untagged files
   // keep the classic postfix naming (EURUSD.QDM)
   string custom, treePath;
   if(srcTag != "")
     {
      custom   = base + "_" + srcTag;
      treePath = InpCustomPath + "\\" + srcTag;
     }
   else
     {
      custom   = base + InpCustomPostfix;
      treePath = InpCustomPath;
     }

   if(!EnsureCustomSymbol(custom, base, treePath))
      return false;

   bool ok;
   datetime lastBar  = 0;
   datetime lastTick = 0;
   if(tf == "TICK")
      ok = ImportTicks(path, custom, lastTick);
   else
      ok = ImportBars(path, custom, lastBar);

   if(ok)
     {
      if(InpVerbose)
         PrintFormat("[QdmImporter] OK  %s -> %s (%s)", fname, custom, tf);
      WriteStatus(custom, srcTag, tf, lastBar, lastTick);
     }
   return ok;
  }

//+------------------------------------------------------------------+
//| Derive base symbol + timeframe from file name                    |
//| Handles QDM Build 124 naming: "EURUSD-M1-No Session.csv"         |
//| plus EURUSD_M1.csv / XAUUSD_TICK.csv / EURUSD.csv                |
//+------------------------------------------------------------------+
bool ParseFileName(const string fname, string &base, string &tf)
  {
   string name = fname;
   int dot = StringFind(name, ".csv");
   if(dot > 0)
      name = StringSubstr(name, 0, dot);

   // normalize QDM's separators: hyphens and spaces -> underscores
   StringToUpper(name);
   StringReplace(name, "-", "_");
   StringReplace(name, " ", "_");

   string parts[];
   int n = StringSplit(name, '_', parts);
   if(n <= 0)
      return false;

   // timeframe = last known TF token in the name
   tf = "";
   for(int i = n - 1; i >= 0 && tf == ""; i--)
      for(int t = 0; t < ArraySize(g_TfTokens); t++)
         if(parts[i] == g_TfTokens[t])
           {
            tf = g_TfTokens[t];
            break;
           }
   if(tf == "")
      tf = "M1";           // default assumption

   base = parts[0];        // leading token = base symbol
   if(IsAllDigits(base))
      return false;         // date stamp from a done-file, not a symbol
   return (StringLen(base) >= 3);
  }

//+------------------------------------------------------------------+
//| Create custom symbol cloned from broker origin (idempotent)      |
//+------------------------------------------------------------------+
bool EnsureCustomSymbol(const string custom, const string base, const string treePath)
  {
   if(SymbolInfoInteger(custom, SYMBOL_EXIST))
     {
      SymbolSelect(custom, true);
      return true;
     }

   // find the broker's variant of the base symbol to clone specs from
   string origin = FindBrokerSymbol(base);

   bool created;
   if(origin != "")
     {
      SymbolSelect(origin, true);
      created = CustomSymbolCreate(custom, treePath, origin);
      if(created && InpVerbose)
         PrintFormat("[QdmImporter] created %s cloned from broker symbol %s", custom, origin);
     }
   else
     {
      // no broker origin -> bare symbol, sane FX defaults
      created = CustomSymbolCreate(custom, treePath);
      if(created)
        {
         CustomSymbolSetInteger(custom, SYMBOL_DIGITS, 5);
         CustomSymbolSetDouble(custom, SYMBOL_POINT, 0.00001);
         CustomSymbolSetDouble(custom, SYMBOL_TRADE_TICK_SIZE, 0.00001);
         CustomSymbolSetDouble(custom, SYMBOL_TRADE_CONTRACT_SIZE, 100000);
         PrintFormat("[QdmImporter] created %s with defaults (no broker origin found for %s) - review specs!", custom, base);
        }
     }

   if(!created)
     {
      PrintFormat("[QdmImporter] FAILED to create %s, err=%d", custom, GetLastError());
      return false;
     }

   if(InpFixedSpreadPts > 0)
      CustomSymbolSetInteger(custom, SYMBOL_SPREAD, InpFixedSpreadPts);

   SymbolSelect(custom, true);
   return true;
  }

//+------------------------------------------------------------------+
//| Resolve base -> broker symbol using suffix candidates            |
//+------------------------------------------------------------------+
string FindBrokerSymbol(const string base)
  {
   string sfx[];
   int n = StringSplit(InpBrokerSuffixes, ',', sfx);
   for(int i = 0; i < n; i++)
     {
      string candidate = base + sfx[i];
      if(SymbolInfoInteger(candidate, SYMBOL_EXIST))
         return candidate;
     }
   // last resort: scan all symbols for prefix match
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string s = SymbolName(i, false);
      if(StringFind(s, base) == 0 && !SymbolInfoInteger(s, SYMBOL_CUSTOM))
         return s;
     }
   return "";
  }

//+------------------------------------------------------------------+
//| BAR IMPORT                                                       |
//+------------------------------------------------------------------+
bool ImportBars(const string path, const string custom, datetime &lastBar)
   {
    int fh = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(fh == INVALID_HANDLE)
      {
       PrintFormat("[QdmImporter] cannot open %s, err=%d", path, GetLastError());
       return false;
      }

    MqlRates rates[];
    ArrayResize(rates, 0, InpChunkBars);
    long totalBars = 0;
    int  badLines  = 0;
    lastBar = 0;

    while(!FileIsEnding(fh))
      {
       string line = FileReadString(fh);
       if(StringLen(line) < 10)
          continue;

       MqlRates r;
       if(!ParseBarLine(line, r))
         {
          badLines++;
          continue;
         }

       if(r.time > lastBar)
          lastBar = r.time;

       int n = ArraySize(rates);
       ArrayResize(rates, n + 1, InpChunkBars);
       rates[n] = r;

       if(n + 1 >= InpChunkBars)
         {
          if(!FlushBars(custom, rates))
            {
             FileClose(fh);
             return false;
            }
          totalBars += ArraySize(rates);
          ArrayResize(rates, 0, InpChunkBars);
         }
      }
    FileClose(fh);

   if(ArraySize(rates) > 0)
     {
      if(!FlushBars(custom, rates))
         return false;
      totalBars += ArraySize(rates);
     }

   if(InpVerbose)
      PrintFormat("[QdmImporter] %s: %I64d bars merged (%d unparsed lines skipped)", custom, totalBars, badLines);
   return (totalBars > 0);
  }

//+------------------------------------------------------------------+
bool FlushBars(const string custom, MqlRates &rates[])
  {
   ResetLastError();
   int written = CustomRatesUpdate(custom, rates);
   if(written < 0)
     {
      PrintFormat("[QdmImporter] CustomRatesUpdate FAILED for %s, err=%d", custom, GetLastError());
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Parse one bar line (comma or tab, combined or split date/time)   |
//+------------------------------------------------------------------+
bool ParseBarLine(const string line, MqlRates &r)
  {
   ushort sep = (StringFind(line, "\t") >= 0) ? '\t' : ',';
   string f[];
   int n = StringSplit(line, sep, f);
   if(n < 5)
      return false;

   // header / non-data line?
   if(StringFind(f[0], "20") != 0 && StringFind(f[0], "19") != 0)
      return false;

   int idx = 1;                                  // index of first price field
   string dt = f[0];
   // separate Date + Time columns?
   if(n >= 6 && StringFind(f[1], ":") >= 0 && StringFind(f[0], " ") < 0)
     {
      dt  = f[0] + " " + f[1];
      idx = 2;
     }

   StringReplace(dt, "-", ".");                  // tolerate yyyy-MM-dd
   dt = NormalizeCompactDate(dt);                // tolerate yyyyMMdd
   r.time = StringToTime(dt);
   if(r.time <= 0)
      return false;

   if(n < idx + 4)
      return false;

   r.open  = StringToDouble(f[idx]);
   r.high  = StringToDouble(f[idx + 1]);
   r.low   = StringToDouble(f[idx + 2]);
   r.close = StringToDouble(f[idx + 3]);
   if(r.open <= 0 || r.high <= 0 || r.low <= 0 || r.close <= 0)
      return false;
   // OHLC consistency: a truncated/corrupt line must never reach
   // CustomRatesUpdate - one invalid bar rejects the whole batch (err 4002)
   if(r.high < r.low)
      return false;
   if(r.open > r.high || r.open < r.low)
      return false;
   if(r.close > r.high || r.close < r.low)
      return false;

   r.tick_volume = (n > idx + 4) ? (long)StringToDouble(f[idx + 4]) : 1;
   if(r.tick_volume <= 0) r.tick_volume = 1;
   r.real_volume = (n > idx + 5) ? (long)StringToDouble(f[idx + 5]) : 0;
   r.spread      = (n > idx + 6) ? (int)StringToDouble(f[idx + 6]) : 0;
   return true;
  }

//+------------------------------------------------------------------+
//| TICK IMPORT                                                      |
//+------------------------------------------------------------------+
bool ImportTicks(const string path, const string custom, datetime &lastTick)
   {
    int fh = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(fh == INVALID_HANDLE)
      {
       PrintFormat("[QdmImporter] cannot open %s, err=%d", path, GetLastError());
       return false;
      }

    MqlTick ticks[];
    ArrayResize(ticks, 0, InpChunkTicks);
    long totalTicks = 0;
    int  badLines   = 0;
    lastTick = 0;

    while(!FileIsEnding(fh))
      {
       string line = FileReadString(fh);
       if(StringLen(line) < 10)
          continue;

       MqlTick t;
       if(!ParseTickLine(line, t))
         {
          badLines++;
          continue;
         }

       datetime tsec = (datetime)(t.time_msc / 1000);
       if(tsec > lastTick)
          lastTick = tsec;

       int n = ArraySize(ticks);
       ArrayResize(ticks, n + 1, InpChunkTicks);
       ticks[n] = t;

       if(n + 1 >= InpChunkTicks)
         {
          if(!FlushTicks(custom, ticks))
            {
             FileClose(fh);
             return false;
            }
          totalTicks += ArraySize(ticks);
          ArrayResize(ticks, 0, InpChunkTicks);
         }
      }
    FileClose(fh);

   if(ArraySize(ticks) > 0)
     {
      if(!FlushTicks(custom, ticks))
         return false;
      totalTicks += ArraySize(ticks);
     }

   if(InpVerbose)
      PrintFormat("[QdmImporter] %s: %I64d ticks replaced (%d unparsed lines skipped)", custom, totalTicks, badLines);
   return (totalTicks > 0);
  }

//+------------------------------------------------------------------+
bool FlushTicks(const string custom, MqlTick &ticks[])
  {
   int n = ArraySize(ticks);
   if(n <= 0)
      return true;
   ResetLastError();
   // replace exactly the window this chunk covers (chunks are chronological)
   int written = CustomTicksReplace(custom, ticks[0].time_msc, ticks[n - 1].time_msc, ticks);
   if(written < 0)
     {
      PrintFormat("[QdmImporter] CustomTicksReplace FAILED for %s, err=%d", custom, GetLastError());
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Parse one tick line. Auto-detects three layouts:                 |
//|   A: EpochMillis,P1,P2[,...]              (Dukascopy raw style)  |
//|   B: Date,Time[.ms],P1,P2[,...]           (QDM split columns)    |
//|   C: DateTime[.ms],P1,P2[,...]            (combined)             |
//| P1/P2 order (bid/ask vs ask/bid) is normalized via min/max.      |
//+------------------------------------------------------------------+
bool ParseTickLine(const string line, MqlTick &t)
  {
   ushort sep = (StringFind(line, "\t") >= 0) ? '\t' : ',';
   string f[];
   int n = StringSplit(line, sep, f);
   if(n < 3)
      return false;

   long msc = 0;
   int  idx = 1;                                // index of first price field

   if(IsAllDigits(f[0]) && StringLen(f[0]) >= 12)
     {
      // layout A: epoch milliseconds
      msc = StringToInteger(f[0]);
     }
   else
     {
      string dt = f[0];
      // layout B: separate Date + Time columns
      if(n >= 4 && StringFind(f[0], " ") < 0 && StringFind(f[1], ":") >= 0)
        {
         dt  = f[0] + " " + f[1];
         idx = 2;
        }
      // header / non-data line?
      if(StringFind(dt, "20") != 0 && StringFind(dt, "19") != 0)
         return false;

      // milliseconds: dot AFTER the space (date part also contains dots)
      int ms = 0;
      int sp = StringFind(dt, " ");
      if(sp > 0)
        {
         int msDot = StringFind(dt, ".", sp);
         if(msDot > 0)
           {
            string msStr = StringSubstr(dt, msDot + 1);
            ms = (int)StringToInteger(msStr);
            if(StringLen(msStr) == 1) ms *= 100;      // ".3"  -> 300ms
            if(StringLen(msStr) == 2) ms *= 10;       // ".32" -> 320ms
            dt = StringSubstr(dt, 0, msDot);
           }
        }
      StringReplace(dt, "-", ".");
      dt = NormalizeCompactDate(dt);
      datetime base = StringToTime(dt);
      if(base <= 0)
         return false;
      msc = (long)base * 1000 + ms;
     }

   if(n < idx + 2)
      return false;

   double p1 = StringToDouble(f[idx]);
   double p2 = StringToDouble(f[idx + 1]);
   if(p1 <= 0 || p2 <= 0 || msc <= 0)
      return false;

   t.time     = (datetime)(msc / 1000);
   t.time_msc = msc;
   t.bid      = MathMin(p1, p2);     // ask >= bid always; normalizes column order
   t.ask      = MathMax(p1, p2);
   t.last     = 0.0;
   t.volume   = 0;                   // Dukascopy volumes are fractional lots; not meaningful here
   t.flags    = TICK_FLAG_BID | TICK_FLAG_ASK;
   return true;
  }

//+------------------------------------------------------------------+
bool SymbolAllowed(const string base)
  {
   int n = ArraySize(g_Filter);
   if(n == 0)
      return true;                 // empty filter = import everything
   for(int i = 0; i < n; i++)
      if(g_Filter[i] == base)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
bool IsAllDigits(const string s)
  {
   int len = StringLen(s);
   if(len == 0)
      return false;
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c < '0' || c > '9')
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| "20260305 00:00:00" -> "2026.03.05 00:00:00" (also bare "20260305")|
//+------------------------------------------------------------------+
string NormalizeCompactDate(const string dtIn)
  {
   string dt = dtIn;
   int sp = StringFind(dt, " ");
   string datePart = (sp > 0) ? StringSubstr(dt, 0, sp) : dt;
   if(StringLen(datePart) == 8 && IsAllDigits(datePart))
     {
      string rest = (sp > 0) ? StringSubstr(dt, sp) : "";
      dt = StringSubstr(datePart, 0, 4) + "." +
           StringSubstr(datePart, 4, 2) + "." +
           StringSubstr(datePart, 6, 2) + rest;
     }
   return dt;
  }

//+------------------------------------------------------------------+
//| Post-import: move to done\ / delete / keep                       |
//+------------------------------------------------------------------+
void FinishFile(const string path, const string fname, const string tfTag, const string srcTag)
  {
   if(InpDonePolicy == "delete")
     {
      FileDelete(path, FILE_COMMON);
      return;
     }
   if(InpDonePolicy == "keep")
      return;

   // default: move (timestamped + tagged so re-exports never collide)
   string stamp = TimeToString(TimeLocal(), TIME_DATE);
   StringReplace(stamp, ".", "");
   string tagPart = (tfTag == "") ? "" : tfTag + "_";
   if(srcTag != "")
      tagPart += srcTag + "_";
   string dst = InpWatchDir + "\\done\\" + stamp + "_" + tagPart + fname;
   if(!FileMove(path, FILE_COMMON, dst, FILE_REWRITE | FILE_COMMON))
      PrintFormat("[QdmImporter] warn: could not move %s to done\\, err=%d", fname, GetLastError());
  }

//+------------------------------------------------------------------+
//| Coverage status (docs/data-gap-backfill.md). Writes per-symbol   |
//| JSON under <watch>\<InpStatusDir>\<custom>.json so the runner    |
//| (run_qdm_daily.ps1 reconcile pass) can verify what MT5 actually  |
//| holds and auto-backfill late-published provider data.            |
//| Status is written on every successful import, independent of the |
//| DonePolicy (file may be kept/deleted after, the record persists).|
//+------------------------------------------------------------------+
void WriteStatus(const string custom, const string srcTag, const string tf,
                 const datetime lastBar, const datetime lastTick)
  {
   if(InpStatusDir == "")
      return;

   string dir = InpWatchDir + "\\" + InpStatusDir;
   FolderCreate(dir, FILE_COMMON);

   string path = dir + "\\" + custom + ".json";

   // read existing record so a M1 write doesn't clobber the TICK value and vice versa
   datetime prevBar  = 0;
   datetime prevTick = 0;
   int rf = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(rf != INVALID_HANDLE)
     {
      string all = "";
      while(!FileIsEnding(rf))
         all += FileReadString(rf, 32768);
      FileClose(rf);
      // crude scan for the two timestamps: "lastBarTime":"...","lastTickTime":"..."
      int b = StringFind(all, "\"lastBarTime\"");
      int t = StringFind(all, "\"lastTickTime\"");
      prevBar  = (b >= 0) ? (datetime)StringToInteger(StringSubstr(all, StringFind(all, ":", b) + 1, 10)) : 0;
      prevTick = (t >= 0) ? (datetime)StringToInteger(StringSubstr(all, StringFind(all, ":", t) + 1, 10)) : 0;
     }

   if(lastBar > prevBar)     prevBar  = lastBar;
   if(lastTick > prevTick)   prevTick = lastTick;

   int wf = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(wf == INVALID_HANDLE)
     {
      PrintFormat("[QdmImporter] cannot write status %s, err=%d", path, GetLastError());
      return;
     }
   string body = "{";
   body += "\"symbol\":\"" + custom + "\",";
   body += "\"source\":\"" + srcTag + "\",";
   body += "\"tf\":\"" + tf + "\",";
   body += "\"lastBarTime\":" + IntegerToString((long)prevBar, 0) + ",";
   body += "\"lastTickTime\":" + IntegerToString((long)prevTick, 0) + ",";
   body += "\"updated\":\"" + TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS) + "\"";
   body += "}";
   FileWrite(wf, body);
   FileClose(wf);

   if(InpVerbose)
      PrintFormat("[QdmImporter] status %s: bar=%ld tick=%ld", custom, (long)prevBar, (long)prevTick);
  }
//+------------------------------------------------------------------+
