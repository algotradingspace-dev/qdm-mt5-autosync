//+------------------------------------------------------------------+
//|                                                   QdmCleanup.mq5 |
//|                          Algo Trading Space - QDM -> MT5 Bridge  |
//|                                                                  |
//| ONE-SHOT SCRIPT (not a Service). Run from MQL5\Scripts\ whenever |
//| you need to wipe every custom symbol this pipeline created -     |
//| e.g. after changing a source's Timezone in config.json, since    |
//| old and newly-shifted timestamps must never be merged into the   |
//| same symbol.                                                     |
//|                                                                  |
//| Deletes any custom symbol whose tree path starts with            |
//| InpPathPrefix (default "Custom\QDM"), after unselecting it from  |
//| Market Watch (required - MT5 refuses to delete a selected        |
//| symbol). Prints a summary; does NOT touch QDM's own database or  |
//| the exported CSV files on disk - run the PowerShell folder wipe  |
//| separately if you also want those cleared.                      |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input string InpPathPrefix = "Custom\\QDM";  // Delete every custom symbol whose path starts with this
input bool   InpLegacyOnly = false;          // true = delete ONLY legacy <SYM><postfix> symbols, keeping the source-tagged ones
input string InpLegacyPostfix = ".QDM";      // The legacy postfix InpLegacyOnly matches on (must equal the service's InpCustomPostfix)
input bool   InpDryRun     = false;          // true = list what WOULD be deleted, delete nothing

//+------------------------------------------------------------------+
//| Legacy naming check.                                              |
//|                                                                   |
//| Source-tagged symbols (EURUSD_dukascopy) live one level deeper,   |
//| at Custom\QDM\<source>, so a bare prefix match on Custom\QDM      |
//| catches BOTH families - which is right for a full wipe and wrong  |
//| for retiring only the legacy ones.                                |
//|                                                                   |
//| Worth retiring on its own: a ".QDM" suffix is stripped by the     |
//| Backtest Manager's normalizeSymbol (it removes a dot-separated    |
//| 1-6 letter suffix), so EURUSD.QDM normalises to EURUSD and        |
//| becomes indistinguishable from the broker's own symbol in any     |
//| tooling that reads this terminal's history. The source-tagged     |
//| names are safe - an underscore is not a stripped separator.       |
//+------------------------------------------------------------------+
bool IsLegacyName(const string name, const string path)
  {
   int plen = StringLen(InpLegacyPostfix);
   if(plen <= 0)
      return false;
   if(StringSubstr(name, StringLen(name) - plen) != InpLegacyPostfix)
      return false;
   // and it must sit directly in the prefix folder, not in a source subfolder
   return (path == InpPathPrefix);
  }

void OnStart()
  {
   int total = SymbolsTotal(false);   // false = all symbols, not just Market Watch
   string toDelete[];
   int    n = 0;

   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      if(!(bool)SymbolInfoInteger(name, SYMBOL_CUSTOM))
         continue;
      string path = SymbolInfoString(name, SYMBOL_PATH);
      if(StringFind(path, InpPathPrefix) != 0)
         continue;
      if(InpLegacyOnly && !IsLegacyName(name, path))
         continue;

      ArrayResize(toDelete, n + 1);
      toDelete[n] = name;
      n++;
     }

   string scope = InpLegacyOnly
                  ? StringFormat("legacy '%s' symbols directly under '%s'", InpLegacyPostfix, InpPathPrefix)
                  : StringFormat("custom symbols under '%s'", InpPathPrefix);

   if(n == 0)
     {
      PrintFormat("[QdmCleanup] No %s. Nothing to do.", scope);
      return;
     }

   PrintFormat("[QdmCleanup] Found %d %s:", n, scope);
   for(int i = 0; i < n; i++)
      PrintFormat("[QdmCleanup]   %s", toDelete[i]);

   if(InpDryRun)
     {
      PrintFormat("[QdmCleanup] DRY RUN - nothing deleted. Set InpDryRun=false to actually delete.");
      return;
     }

   int okCount = 0, failCount = 0;
   for(int i = 0; i < n; i++)
     {
      string name = toDelete[i];
      SymbolSelect(name, false);           // must be unselected before delete
      ResetLastError();
      if(CustomSymbolDelete(name))
        {
         okCount++;
        }
      else
        {
         failCount++;
         PrintFormat("[QdmCleanup] FAILED to delete %s, err=%d (still selected somewhere, or open chart uses it?)",
                     name, GetLastError());
        }
     }

   PrintFormat("[QdmCleanup] Done. Deleted %d, failed %d.", okCount, failCount);
   if(failCount > 0)
      PrintFormat("[QdmCleanup] For failures: close any chart using that symbol and re-run this script.");
  }
//+------------------------------------------------------------------+
