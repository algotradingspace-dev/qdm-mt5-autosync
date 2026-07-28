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
input bool   InpDryRun     = false;          // true = list what WOULD be deleted, delete nothing

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

      ArrayResize(toDelete, n + 1);
      toDelete[n] = name;
      n++;
     }

   if(n == 0)
     {
      PrintFormat("[QdmCleanup] No custom symbols found under '%s'. Nothing to do.", InpPathPrefix);
      return;
     }

   PrintFormat("[QdmCleanup] Found %d custom symbol(s) under '%s':", n, InpPathPrefix);
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
