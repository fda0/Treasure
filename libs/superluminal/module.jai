#load "PerformanceAPI_capi.jai";

PerfColor :: PERFORMANCEAPI_MAKE_COLOR;
PerfDefaultColor :: PERFORMANCEAPI_DEFAULT_COLOR;

PerfScope :: (name: string, color := PerfDefaultColor) #expand #no_debug
{
   PerfFuncs.BeginEventN(name.data, xx name.count, null, 0, color);
   `defer PerfFuncs.EndEvent();
}

PerfInit :: ()
{
   #import "Windows";
   #import "Basic";

   module := LoadLibraryA("PerformanceAPI.dll");
   if !module
   {
      log_error("Failed to load library PerformanceAPI.dll");
      return;
   }

   get_api_address := GetProcAddress(module, "PerformanceAPI_GetAPI");
   if !get_api_address
   {
      log_error("Failed to load address of PerformanceAPI_GetAPI");
      return;
   }

   get_api := get_api_address.(PerformanceAPI_GetAPI_Func);
   result := get_api(PERFORMANCEAPI_VERSION, *PerfFuncs);
   if result == 0
   {
      log_error("PerformanceAPI_GetAPI returned 0 (version mismatch)");
      exit(1);
   }
}

PerfFuncs: PerformanceAPI_Functions;
