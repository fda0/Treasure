/*
THIS CODE WAS MANUALLY PORTED TO JAI

BSD LICENSE

Copyright (c) 2019-2020 Superluminal. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

PERFORMANCEAPI_ENABLED :: false;

PERFORMANCEAPI_MAJOR_VERSION : s32 : 3;
PERFORMANCEAPI_MINOR_VERSION : s32 : 0;
PERFORMANCEAPI_VERSION : s32 : ((PERFORMANCEAPI_MAJOR_VERSION << 16) | PERFORMANCEAPI_MINOR_VERSION);

/**
 * This header has been designed to be fully self-contained, which makes it easy to copy this header into your own source tree as needed.
 *
 * See PerformanceAPI.h for the high level documentation on how to use the API.
 *
 * Note that this header is split into two sections:
 * - The first section defines the static library interface. If you use these functions directly, you need to link against the PerformanceAPI static library.
 * - The second section defines the DLL interface. The DLL interface allows you to use the API without linking to a library. Instead, you can load the DLL yourself
 *   through LoadLibrary, then find the "PerformanceAPI_GetAPI" export through GetProcAddress. PerformanceAPI_GetAPI can be called to get a table of function pointers
 *   to the API. A convenience function to perform the DLL load & retrieve the API functions is provided for you in a separate header, PerformanceAPI_loader.h.
 */

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Static library interface - if you use these functions, you need to link against the PerformanceAPI library
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Helper function to create an uint32_t color from 3 RGB values. The R, G and B values must be in range [0, 255].
 * The resulting color can be passed to the BeginEvent function.
 */
PERFORMANCEAPI_MAKE_COLOR :: (R: u32, G: u32, B: u32) -> u32 #expand
{
  return (R << 24) | (G << 16) | (B << 8) | (0xFF);
}

/**
 * Use this define if you don't care about the color of an event and just want to use the default
 */
PERFORMANCEAPI_DEFAULT_COLOR: u32 : 0xFFFFFFFF;

/**
 * Helper struct that is used to prevent calls to EndEvent from being optimized to jmp instructions as part of tail call optimization.
 * You don't ever need to do anything with this as user of the API.
 */
PerformanceAPI_SuppressTailCallOptimization :: struct
{
  SuppressTailCall: [3] s64;
}

#if PERFORMANCEAPI_ENABLED {
  PerfomanceAPIlib :: #library,no_dll "PerformanceAPI_MD"; // STATIC LINKING IN JAI
  CppRuntimeLibrary :: #library,no_dll "vcruntime";

  /**
   * Set the name of the current thread to the specified thread name.
   *
   * @param inThreadName The thread name as an UTF8 encoded string.
   */
  // PerformanceAPI_SetCurrentThreadName :: (inThreadName: *u8) #foreign PerfomanceAPIlib;

  /**
   * Set the name of the current thread to the specified thread name.
   *
   * @param inThreadName The thread name as an UTF8 encoded string.
   * @param inThreadNameLength The length of the thread name, in characters, excluding the null terminator.
   */
  // PerformanceAPI_SetCurrentThreadName_N :: (inThreadName: *u8, inThreadNameLength: u16) #foreign PerfomanceAPIlib;

  /**
   * Begin an instrumentation event with the specified ID and runtime data
   *
   * @param inID    The ID of this scope as an UTF8 encoded string. The ID for a specific scope must be the same over the lifetime of the program (see docs at the top of this file)
   * @param inData  [optional] The data for this scope as an UTF8 encoded string. The data can vary for each invocation of this scope and is intended to hold information that is only available at runtime. See docs at the top of this file.
   *							 Set to null if not available.
   * @param inColor [optional] The color for this scope. The color for a specific scope is coupled to the ID and must be the same over the lifetime of the program
   *							 Set to PERFORMANCEAPI_DEFAULT_COLOR to use default coloring.
   *
   */
  // PerformanceAPI_BeginEvent :: (inID: *u8, inData: *u8, inColor: u32) #foreign PerfomanceAPIlib;

  /**
   * Begin an instrumentation event with the specified ID and runtime data, both with an explicit length.

   * It works the same as the regular BeginEvent function (see docs above). The difference is that it allows you to specify the length of both the ID and the data,
   * which is useful for languages that do not have null-terminated strings.
   *
   * Note: both lengths should be specified in the number of characters, not bytes, excluding the null terminator.
   */
  PerformanceAPI_BeginEvent_N :: (inID: *u8, inIDLength: u16, inData: *u8, inDataLength: u16, inColor: u32) #foreign PerfomanceAPIlib;

  /**
   * Begin an instrumentation event with the specified ID and runtime data
   *
   * @param inID    The ID of this scope as an UTF16 encoded string. The ID for a specific scope must be the same over the lifetime of the program (see docs at the top of this file)
   * @param inData  [optional] The data for this scope as an UTF16 encoded string. The data can vary for each invocation of this scope and is intended to hold information that is only available at runtime. See docs at the top of this file.
                   Set to null if not available.
   * @param inColor [optional] The color for this scope. The color for a specific scope is coupled to the ID and must be the same over the lifetime of the program
   *							 Set to PERFORMANCEAPI_DEFAULT_COLOR to use default coloring.
   */
  // PerformanceAPI_BeginEvent_Wide :: (inID: *u16, inData: *u16, inColor: u32) #foreign PerfomanceAPIlib;

  /**
   * Begin an instrumentation event with the specified ID and runtime data, both with an explicit length.

   * It works the same as the regular BeginEvent_Wide function (see docs above). The difference is that it allows you to specify the length of both the ID and the data,
   * which is useful for languages that do not have null-terminated strings.
   *
   * Note: both lengths should be specified in the number of characters, not bytes, excluding the null terminator.
   */
  // PerformanceAPI_BeginEvent_Wide_N :: (inID: *u16, inIDLength: u16, inData: *u16, inDataLength: u16, inColor: u32) #foreign PerfomanceAPIlib;

  /**
   * End an instrumentation event. Must be matched with a call to BeginEvent within the same function
   * Note: the return value can be ignored. It is only there to prevent calls to the function from being optimized to jmp instructions as part of tail call optimization.
   */
  PerformanceAPI_EndEvent :: () -> PerformanceAPI_SuppressTailCallOptimization #foreign PerfomanceAPIlib;

  /**
   * Call this function when a fiber starts running
   *
   * @param inFiberID    The currently running fiber
   */
  // PerformanceAPI_RegisterFiber :: (inFiberID: u64) #foreign PerfomanceAPIlib;

  /**
   * Call this function before a fiber ends
   *
   * @param inFiberID    The currently running fiber
   */
  // PerformanceAPI_UnregisterFiber :: (inFiberID: u64) #foreign PerfomanceAPIlib;

  /**
   * The call to the Windows SwitchFiber function should be surrounded by BeginFiberSwitch and EndFiberSwitch calls. For example:
   *
   *		PerformanceAPI_BeginFiberSwitch(currentFiber, otherFiber);
   *		SwitchToFiber(otherFiber);
   *		PerformanceAPI_EndFiberSwitch(currentFiber);
   *
   * @param inCurrentFiberID    The currently running fiber
   * @param inNewFiberID		  The fiber we're switching to
   */
  // PerformanceAPI_BeginFiberSwitch :: (inCurrentFiberID: u64, inNewFiberID: u64) #foreign PerfomanceAPIlib;

  /**
   * The call to the Windows SwitchFiber function should be surrounded by BeginFiberSwitch and EndFiberSwitch calls
   *
   *		PerformanceAPI_BeginFiberSwitch(currentFiber, otherFiber);
   *		SwitchToFiber(otherFiber);
   *		PerformanceAPI_EndFiberSwitch(currentFiber);
   *
   * @param inFiberID    The fiber that was running before the call to SwitchFiber (so, the same as inCurrentFiberID in the BeginFiberSwitch call)
   */
  // PerformanceAPI_EndFiberSwitch :: (inFiberID: u64) #foreign PerfomanceAPIlib;
} else { // PERFORMANCEAPI_ENABLED == false
  PerformanceAPI_SetCurrentThreadName :: (#discard inThreadName: *u8) #expand {}
  PerformanceAPI_SetCurrentThreadName_N :: (#discard inThreadName: *u8, #discard inThreadNameLength: u16) #expand {}
  PerformanceAPI_BeginEvent :: (#discard inID: *u8, #discard inData: *u8, #discard inColor: u32) #expand {}
  PerformanceAPI_BeginEvent_N :: (#discard inID: *u8, #discard inIDLength: u16, #discard inData: *u8, #discard inDataLength: u16, #discard inColor: u32) #expand {}
  PerformanceAPI_BeginEvent_Wide :: (#discard inID: *u16, #discard inData: *u16, #discard inColor: u32) #expand {}
  PerformanceAPI_BeginEvent_Wide_N :: (#discard inID: *u16, #discard inIDLength: u16, #discard inData: *u16, #discard inDataLength: u16, #discard inColor: u32) #expand {}
  PerformanceAPI_EndEvent :: () #expand {}

  PerformanceAPI_RegisterFiber :: (#discard inFiberID: u64) #expand {}
  PerformanceAPI_UnregisterFiber :: (#discard inFiberID: u64) #expand {}
  PerformanceAPI_BeginFiberSwitch :: (#discard inCurrentFiberID: u64, #discard inNewFiberID: u64) #expand {}
  PerformanceAPI_EndFiberSwitch :: (#discard inFiberID: u64) #expand {}
} // PERFORMANCEAPI_ENABLED

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// DLL interface - These functions can be used without linking by loading PerformanceAPI.dll and using GetProcAddress to find the PerformanceAPI_GetAPI function.
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

PerformanceAPI_SetCurrentThreadName_Func :: #type (inThreadName: *u8) -> void #c_call;
PerformanceAPI_SetCurrentThreadName_N_Func :: #type (inThreadName: *u8, inThreadNameLength: u16) -> void #c_call;
PerformanceAPI_BeginEvent_Func :: #type (inID: *u8, inData: *u8, inColor: u32) -> void #c_call;
PerformanceAPI_BeginEvent_N_Func :: #type (inID: *u8, inIDLength: u16, inData: *u8, inDataLength: u16, inColor: u32) -> void #c_call;
PerformanceAPI_BeginEvent_Wide_Func :: #type (inID: *u16, inData: *u16, inColor: u32) -> void #c_call;
PerformanceAPI_BeginEvent_Wide_N_Func :: #type (inID: *u16, inIDLength: u16, inData: *u16, inDataLength: u16, inColor: u32) -> void #c_call;
PerformanceAPI_EndEvent_Func :: #type () -> PerformanceAPI_SuppressTailCallOptimization #c_call;

PerformanceAPI_RegisterFiber_Func :: #type (inFiberID: u64) -> PerformanceAPI_SuppressTailCallOptimization #c_call;
PerformanceAPI_UnregisterFiber_Func :: #type (inFiberID: u64) -> PerformanceAPI_SuppressTailCallOptimization #c_call;
PerformanceAPI_BeginFiberSwitch_Func :: #type (inCurrentFiberID: u64, inNewFiberID: u64) -> PerformanceAPI_SuppressTailCallOptimization #c_call;
PerformanceAPI_EndFiberSwitch_Func :: #type (inFiberID: u64) -> PerformanceAPI_SuppressTailCallOptimization #c_call;

PerformanceAPI_Functions :: struct
{
  SetCurrentThreadName: PerformanceAPI_SetCurrentThreadName_Func;
  SetCurrentThreadNameN: PerformanceAPI_SetCurrentThreadName_N_Func;
  BeginEvent: PerformanceAPI_BeginEvent_Func;
  BeginEventN: PerformanceAPI_BeginEvent_N_Func;
  BeginEventWide: PerformanceAPI_BeginEvent_Wide_Func;
  BeginEventWideN: PerformanceAPI_BeginEvent_Wide_N_Func;
  EndEvent: PerformanceAPI_EndEvent_Func;

  RegisterFiber: PerformanceAPI_RegisterFiber_Func;
  UnregisterFiber: PerformanceAPI_UnregisterFiber_Func;
  BeginFiberSwitch: PerformanceAPI_BeginFiberSwitch_Func;
  EndFiberSwitch: PerformanceAPI_EndFiberSwitch_Func;
}

/**
 * Entry point for the PerformanceAPI when used through a DLL. You can get the actual function from the DLL through
 * GetProcAddress and then cast it to this function pointer. The name of the function exported from the DLL is "PerformanceAPI_GetAPI".
 *
 * A convenience function to find & call this function from the PerformanceAPI dll is provided in a separate header, PerformanceAPI_loader.h (PerformanceAPI_LoadFrom)
 *
 * @param inVersion The version of the header that's used to request the function table. Always specify PERFORMANCEAPI_VERSION for this argument (defined at the top of this file).
 *					Note: the version of the header and DLL must match exactly; if it doesn't an error will be returned.
 * @param outFunctions Pointer to a PerformanceAPI_Functions struct that will be filled with the correct function pointers to use the API
 *
 * @return 0 if there was an error (version mismatch), 1 on success
 */
PerformanceAPI_GetAPI_Func :: #type (inVersion: s32, outFunctions: *PerformanceAPI_Functions) -> s32 #c_call;
