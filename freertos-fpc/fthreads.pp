{
    This file is part of the Free Pascal run time library.
    Copyright (c) 2002 by Peter Vreman,
    member of the Free Pascal development team.

    FreeRTOS threading support implementation

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}

unit fthreads;

interface

const
  DefaultStackSize = 1024;

procedure FreeRTOSTaskWrapper(param: pointer);

{ every platform can have it's own implementation of GetCPUCount; use the define
  HAS_GETCPUCOUNT to disable the default implementation which simply returns 1 }
function GetCPUCount: LongWord;

property CPUCount: LongWord read GetCPUCount;

implementation

uses
  task, semphr, portmacro, portable;

const
// FreeRTOS have some TLS space per task, use DataIndex to identify the
// location of FPC's TLS pointer in this space
// TODO: check if FPC TLS space required can fit into the FreeRTOS TLS block, could save memory that way.
  DataIndex: PtrUInt = 1; // Not 0 purely for debugging, nothing else currently use the TLS space
  ThreadVarBlockSize: dword = 0;
  TLSAPISupported: boolean = false;
  pdTRUE = 1;

var
  FreeRTOSThreadManager: TThreadManager;

procedure HandleError(Errno : Longint); external name 'FPC_HANDLEERROR';
procedure fpc_threaderror; [external name 'FPC_THREADERROR'];

procedure SysInitThreadvar (var Offset: dword; Size: dword);
begin
  Offset := ThreadVarBlockSize;
  Inc (ThreadVarBlockSize, Size);
end;

procedure SysAllocateThreadVars;
var
  p: pointer;
begin
  { we've to allocate the memory from the OS }
  { because the FPC heap management uses     }
  { exceptions which use threadvars but      }
  { these aren't allocated yet ...           }
  { allocate room on the heap for the thread vars }
  if TLSAPISupported then // let's stick with the FreeRTOS TLS block for now
  begin
    p := pvPortMalloc(ThreadVarBlockSize);
    vTaskSetThreadLocalStoragePointer(nil, DataIndex, p);
  end
  else
    HandleError(3); // path not found, meaning TLS is not available on target

  // Zero fill thread storage block
  FillChar(p^, 0, ThreadVarBlockSize);
end;


function SysRelocateThreadVar(Offset: dword): pointer;
var
  p: pointer;
begin
  p := pvTaskGetThreadLocalStoragePointer(nil, DataIndex);
  if p = nil then
  begin
    RunError(232);
    //SysAllocateThreadVars;
    //InitThread($400);  // Default to 1 kB stack
    //p := pvTaskGetThreadLocalStoragePointer(nil, DataIndex);
  end;

  SysRelocateThreadVar := p + Offset;
end;


procedure SysInitMultithreading;
var
  RC: cardinal;
  p: pointer;
begin
  { do not check IsMultiThread, as program could have altered it, out of Delphi habit }

  { the thread attach/detach code uses locks to avoid multiple calls of this }
  // consider here only the FreeRTOS provided TLS space for now
  p := pvTaskGetThreadLocalStoragePointer(nil, DataIndex);
  if p = nil then // FPC TLS space not allocated
  begin
    p := pvPortMalloc(SizeOf(PtrUInt));
    if p <> nil then
    begin
      vTaskSetThreadLocalStoragePointer(nil, DataIndex, p);  // Require configNUM_THREAD_LOCAL_STORAGE_POINTERS to be set
      FreeRTOSThreadManager.RelocateThreadVar := @SysRelocateThreadVar;
      //CurrentTM.RelocateThreadVar := @SysRelocateThreadVar;
      // TODO: Threadvar support not yet working
      //InitThreadVars(@SysRelocateThreadVar);

      IsMultiThread := true;
    end
    else
    begin
      TLSAPISupported := false;
      RunError(204); // Invalid pointer operation
    end;
  end;
end;


procedure SysFiniMultithreading;
var
 p: pointer;
begin
  if IsMultiThread then
  begin
    if TLSAPISupported then
    begin
      p := pvTaskGetThreadLocalStoragePointer(nil, DataIndex);
      if p <> nil then
        vPortFree(p);
    end
  end;
end;


procedure SysReleaseThreadVars;
var
  p: pointer;
begin
  if TLSAPISupported then
  begin
    p := pvTaskGetThreadLocalStoragePointer(nil, DataIndex);
    if p <> nil then
      vPortFree(p);
  end
  else
    RunError(3);
end;

{*****************************************************************************
                            Thread starting
*****************************************************************************}

type
  pthreadinfo = ^tthreadinfo;
  tthreadinfo = record
    f : tthreadfunc;
    p : pointer;
    stklen : cardinal;
  end;


function ThreadMain(param : pointer) : pointer;cdecl;
var
  ti : tthreadinfo;
begin
  { Allocate local thread vars, this must be the first thing,
    because the exception management and io depends on threadvars }
  SysAllocateThreadVars;
  { Copy parameter to local data }
{$ifdef DEBUG_MT}
  writeln('New thread started, initialising ...');
{$endif DEBUG_MT}
  ti := pthreadinfo(param)^;
  dispose(pthreadinfo(param));
  { Initialize thread }
  InitThread(ti.stklen);
  { Start thread function }
{$ifdef DEBUG_MT}
  writeln('Jumping to thread function');
{$endif DEBUG_MT}
  ThreadMain := pointer(ti.f(ti.p));
end;

// FreeRTOS tasks are defined as procedure (param: pointer),
// while TThreadFunc is defined as function(parameter : pointer) : ptrint;
// Use a wrapper procedure with TTaskFunc signature to run a thread
procedure FreeRTOSTaskWrapper(param: pointer);
var
  res: ptrint;
begin
  res := PThreadInfo(param)^.f(PThreadInfo(param)^.p);
  // TODO: Store exit value...
end;


function SysBeginThread (SA: pointer; StackSize : PtrUInt;
                         ThreadFunction: TThreadFunc; P: pointer;
                         CreationFlags: dword; var ThreadId: TThreadID): TThreadID;
var
  TI: PThreadInfo;
  RC: cardinal;
begin
{ WriteLn is not a good idea before thread initialization...
  $ifdef DEBUG_MT
  WriteLn ('Creating new thread');
 $endif DEBUG_MT}
{ Initialize multithreading if not done }
  SysInitMultithreading;
{ the only way to pass data to the newly created thread
  in a MT safe way, is to use the heap }
  New(TI);
  TI^.F := ThreadFunction;
  TI^.P := P;
  TI^.StkLen := StackSize;
  ThreadID := 0;
{$ifdef DEBUG_MT}
  WriteLn ('Starting new thread');
{$endif DEBUG_MT}

  RC := xTaskCreate(@FreeRTOSTaskWrapper,  // pointer to wrapper procedure
                    'FPC-thread',          // task name, cannot yet assign a debug name after task creation
                    StackSize,             // ...
                    TI,                    // Thread info passed as parameter
                    1,                     // Priority, idle task priority is 0, so make this slightly higher
                    @ThreadID);            // Task handle to created task

  if RC = pdTRUE then
    SysBeginThread := ThreadID
  else
  begin
    SysBeginThread := 0;
{$IFDEF DEBUG_MT}
    WriteLn ('Thread creation failed');
{$ENDIF DEBUG_MT}
    Dispose (TI);
    RunError(203); // Only failure value defined is errCOULD_NOT_ALLOCATE_REQUIRED_MEMORY
  end;
end;


procedure SysEndThread (ExitCode: cardinal);
begin
  DoneThread;
  vTaskDelete(nil); // delete current task
  ExitCode := 0; // TODO: propagate exit code
end;


procedure SysThreadSwitch;
begin
  taskYield;
end;


function SysSuspendThread (ThreadHandle: TThreadID): dword;
var
  RC: cardinal;
begin
  vTaskSuspend(pointer(ThreadHandle));
  SysSuspendThread := 0;
end;


function SysResumeThread (ThreadHandle: TThreadID): dword;
begin
  vTaskResume(pointer(ThreadHandle));
  SysResumeThread := 0;
end;

function SysKillThread (ThreadHandle: TThreadID): dword;
begin
  vTaskDelete(TTaskHandle(ThreadHandle)); // no finesse...
  SysKillThread := 0;
end;

{$PUSH}
{$WARNINGS OFF}
function SysCloseThread (ThreadHandle: TThreadID): dword;
begin
  // ??
end;
{$POP}

function SysWaitForThreadTerminate (ThreadHandle: TThreadID;
                                    TimeoutMs: longint): dword;
begin
  // FreeRTOS doesn't have something like this that I know of.
  // Perhaps can call xTaskNotify, but then the task loop must check for a notification...
  // Or call vTaskGetInfo in a loop and check TTaskStatus - but this is not available for esp-idf
  SysWaitForThreadTerminate := 1;
end;

function SysThreadSetPriority(ThreadHandle: TThreadID; Prio: longint): boolean;
{0..some small positive number, idle priority is 0, most SDK tasks seem to run at level 1}
begin
  if Prio < 0 then
    Prio := 0;
  vTaskPrioritySet(TTaskHandle(ThreadHandle), Prio);
  Result := true;
end;


function SysThreadGetPriority(ThreadHandle: TThreadID): longint;
begin
  SysThreadGetPriority := uxTaskPriorityGet(TTaskHandle(ThreadHandle));
end;


function SysGetCurrentThreadID: TThreadID;
begin
  SysGetCurrentThreadID := TThreadID(xTaskGetCurrentTaskHandle);
end;

procedure SysSetThreadDebugNameA(threadHandle: TThreadID; const ThreadName: AnsiString);
begin
  {$Warning SetThreadDebugName needs to be implemented}
  // Name can only be set at task creation time
end;


procedure SysSetThreadDebugNameU(threadHandle: TThreadID; const ThreadName: UnicodeString);
begin
  {$Warning SetThreadDebugName needs to be implemented}
end;


procedure SysInitCriticalSection(var CS);
begin
  TSemaphoreHandle(CS) := xSemaphoreCreateMutex;
  if pointer(CS) = nil then
  begin
    FPC_ThreadError;
  end;
end;

procedure SysDoneCriticalSection(var CS);
begin
  xSemaphoreGiveRecursive(TSemaphoreHandle(CS));
  vSemaphoreDelete(TSemaphoreHandle(CS));
end;

procedure SysEnterCriticalSection(var CS);
var
  RC: cardinal;
begin
  RC := xSemaphoreTake(TSemaphoreHandle(CS), portMAX_DELAY);
  if RC <> pdTRUE then
  begin
    FPC_ThreadError;
  end;
end;

function SysTryEnterCriticalSection(var CS): longint;
begin
  if xSemaphoreTake(TSemaphoreHandle(CS), 0) = pdTRUE then
    Result := 1
  else
    Result := 0;
end;

procedure SysLeaveCriticalSection(var CS);
var
  RC: cardinal;
begin
  RC := xSemaphoreGive(TSemaphoreHandle(CS));
  if RC <> pdTRUE then
  begin
     FPC_ThreadError;
  end;
end;

type
  TBasicEventState = record
    FHandle: TSemaphoreHandle;
    FLastError: longint;
  end;
  PLocalEventRec = ^TBasicEventState;


const
  wrSignaled  = 0;
  wrTimeout   = 1;
  wrAbandoned = 2;  (* This cannot happen for an event semaphore with OS/2? *)
  wrError     = 3;
  Error_Timeout = 640;
  OS2SemNamePrefix = '\SEM32\';  // Remain OS2 compatible?

// initialstate = true means semaphore is owned by current thread, others waiting on this will block
function SysBasicEventCreate (EventAttributes: Pointer;
     AManualReset, InitialState: boolean; const Name: ansistring): PEventState;
begin
  New(PLocalEventRec(Result));
  PLocalEventRec(Result)^.FHandle := xSemaphoreCreateMutex;
  if PLocalEventRec(Result)^.FHandle = nil then
  begin
    Dispose (PLocalEventRec (Result));
    FPC_ThreadError;
  end
  else if InitialState then
    xSemaphoreTake(PLocalEventRec(Result)^.FHandle, 0);  // No timeout given because sem is not yet visible elsewhere
end;


procedure SysBasicEventDestroy (State: PEventState);
var
  RC: cardinal;
begin
  if State = nil then
    FPC_ThreadError
  else
    vSemaphoreDelete(PLocalEventRec (State)^.FHandle);
end;


procedure SysBasicEventResetEvent (State: PEventState);
var
  PostCount: cardinal;
  RC: cardinal;
begin
  if State = nil then
    FPC_ThreadError
  else
  begin
    if xSemaphoreGive(PLocalEventRec(State)^.FHandle) <> pdTRUE then
      FPC_ThreadError;
  end;
end;


procedure SysBasicEventSetEvent (State: PEventState);
var
  RC: cardinal;
begin
  //if State = nil then
  //  FPC_ThreadError
  //else
  //begin
  //
  //  RC := DosPostEventSem (PLocalEventRec (State)^.FHandle);
  //  if RC <> 0 then
  //   OSErrorWatch (RC);
  // end;
end;


function SysBasicEventWaitFor (Timeout: Cardinal; State: PEventState): longint;
var
  RC: cardinal;
begin
  //if State = nil then
  // FPC_ThreadError
  //else
  // begin
  //  RC := DosWaitEventSem (PLocalEventRec (State)^.FHandle, Timeout);
  //  case RC of
  //   0: Result := wrSignaled;
  //   Error_Timeout: Result := wrTimeout;
  //  else
  //   begin
  //    Result := wrError;
  //    OSErrorWatch (RC);
  //    PLocalEventRec (State)^.FLastError := RC;
  //   end;
  //  end;
  // end;
end;


function SysRTLEventCreate: PRTLEvent;
begin
  Result := PRTLEvent(xSemaphoreCreateBinary);
  if Result = nil then
    FPC_ThreadError;
end;


procedure SysRTLEventDestroy (AEvent: PRTLEvent);
begin
  vSemaphoreDelete(TSemaphoreHandle(AEvent));
end;


procedure SysRTLEventSetEvent (AEvent: PRTLEvent);
begin
  // First obtain semaphore before giving it
  if xSemaphoreTake(TSemaphoreHandle(AEvent), 10) = pdTRUE then
    xSemaphoreGive(TSemaphoreHandle(AEvent))
  else
    FPC_ThreadError;
end;


procedure SysRTLEventWaitFor (AEvent: PRTLEvent);
begin
  if not (xSemaphoreTake(TSemaphoreHandle(AEvent), portMAX_DELAY) = pdTRUE) then
    FPC_ThreadError;
end;


// Timeout in ms
procedure SysRTLEventWaitForTimeout (AEvent: PRTLEvent; Timeout: longint);
begin
  xSemaphoreTake(TSemaphoreHandle(AEvent), Timeout div portTICK_PERIOD_MS);
end;


procedure SysRTLEventResetEvent (AEvent: PRTLEvent);
begin
  if not (xSemaphoreTake(TSemaphoreHandle(AEvent), 0) = pdTRUE) then
    FPC_ThreadError;
end;


{$DEFINE HAS_GETCPUCOUNT}
function GetCPUCount: LongWord;
begin
  // FreeRTOS doesn't have a GetCPUCount equivalent...
  {$ifdef FPC_MCU_ESP32}
  GetCPUCount := 2;
  {$else}
  GetCPUCount := 1;
  {$endif}
end;


procedure InitSystemThreads;
begin
  with FreeRTOSThreadManager do
  begin
    InitManager            :=Nil;
    DoneManager            :=Nil;
    BeginThread            := @SysBeginThread;
    EndThread              := @SysEndThread;
    SuspendThread          := @SysSuspendThread;
    ResumeThread           := @SysResumeThread;
    KillThread             := @SysKillThread;
    CloseThread            := @SysCloseThread;
    ThreadSwitch           := @SysThreadSwitch;
    WaitForThreadTerminate := @SysWaitForThreadTerminate;
    ThreadSetPriority      := @SysThreadSetPriority;
    ThreadGetPriority      := @SysThreadGetPriority;
    GetCurrentThreadId     := @SysGetCurrentThreadId;
    SetThreadDebugNameA    := @SysSetThreadDebugNameA;
    {$ifdef FPC_HAS_FEATURE_UNICODESTRINGS}
    SetThreadDebugNameU    := @SysSetThreadDebugNameU;
    {$endif FPC_HAS_FEATURE_UNICODESTRINGS}
    InitCriticalSection    := @SysInitCriticalSection;
    DoneCriticalSection    := @SysDoneCriticalSection;
    EnterCriticalSection   := @SysEnterCriticalSection;
    TryEnterCriticalSection:= @SysTryEnterCriticalSection;
    LeaveCriticalSection   := @SysLeaveCriticalSection;
    InitThreadVar          := @SysInitThreadVar;
    RelocateThreadVar      := @SysRelocateThreadVar;
    AllocateThreadVars     := @SysAllocateThreadVars;
    ReleaseThreadVars      := @SysReleaseThreadVars;
    BasicEventCreate       :=nil;//@SysBasicEventCreate;
    BasicEventDestroy      :=nil;//@SysBasicEventDestroy;
    BasicEventSetEvent     :=nil;//@SysBasicEventSetEvent;
    BasicEventResetEvent   :=nil;//@SysBasicEventResetEvent;
    BasiceventWaitFor      :=nil;//@SysBasiceventWaitFor;
    RTLEventCreate         := @SysRTLEventCreate;
    RTLEventDestroy        := @SysRTLEventDestroy;
    RTLEventSetEvent       := @SysRTLEventSetEvent;
    RTLEventResetEvent     := @SysRTLEventResetEvent;
    RTLEventWaitFor        := @SysRTLEventWaitFor;
    RTLEventWaitForTimeout := @SysRTLEventWaitForTimeout;
  end;
  SetThreadManager(FreeRTOSThreadManager);
end;

initialization
  if ThreadingAlreadyUsed then
    begin
      writeln('Threading has been used before cthreads was initialized.');
      writeln('Make cthreads one of the first units in your uses clause.');
      runerror(211);
    end;
  InitSystemThreads;

finalization

end.
