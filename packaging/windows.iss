#define AppVersion "1.1.0"
[Setup]
#ifdef InstallerTest
AppId=ScreenClip-InstallerVerification
Uninstallable=no
#else
AppId={{E02AFC24-63BD-4C11-93AC-83D643717E92}
#endif
AppName=定格T
AppVersion={#AppVersion}
AppPublisher=定格T
AppPublisherURL=https://github.com/haoyuanwu/screen_clip_win
DefaultDirName={localappdata}\Programs\ScreenClip
DefaultGroupName=定格T
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\dist
OutputBaseFilename=ScreenClip-{#AppVersion}-Windows-x64-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\screen_clip_win.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Application-specific preflight below handles all running copies, including
; portable or previous installations outside the chosen destination.
CloseApplications=no
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoDescription=定格T安装程序（跨目录自动退出修复）
[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
[Tasks]
Name: "closeapp"; Description: "安装前自动退出正在运行的定格T"
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifndef InstallerTest
[Icons]
Name: "{group}\定格T截图"; Filename: "{app}\screen_clip_win.exe"
Name: "{autodesktop}\定格T截图"; Filename: "{app}\screen_clip_win.exe"; Tasks: desktopicon
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "ScreenClip"; Flags: dontcreatekey uninsdeletevalue
#endif
[Run]
Filename: "{app}\screen_clip_win.exe"; Description: "启动定格T截图（默认开机启动，可在偏好设置中关闭）"; Flags: nowait postinstall skipifsilent

[Code]
function ExitOpenProcess(Access: LongWord; Inherit: Boolean; ProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function ExitCloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function ExitQueryPath(Handle: THandle; Flags: LongWord; Path: String; var Size: LongWord): Boolean;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';
function ExitGetProcessId(Window: HWND; var ProcessId: LongWord): LongWord;
  external 'GetWindowThreadProcessId@user32.dll stdcall';
function ExitGetSessionId(ProcessId: LongWord; var SessionId: LongWord): Boolean;
  external 'ProcessIdToSessionId@kernel32.dll stdcall';
function ExitCurrentProcessId: LongWord;
  external 'GetCurrentProcessId@kernel32.dll stdcall';
function ExitFindWindow(Parent, Previous: HWND; ClassName: String; WindowName: NativeUInt): HWND;
  external 'FindWindowExW@user32.dll stdcall';
function ExitWait(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function ExitTerminate(Handle: THandle; ExitCode: LongWord): Boolean;
  external 'TerminateProcess@kernel32.dll stdcall';

function ExitVersionSize(FileName: String; var Ignored: LongWord): LongWord;
  external 'GetFileVersionInfoSizeW@version.dll stdcall';
function ExitVersionInfo(FileName: String; Ignored, Size: LongWord; Buffer: String): Boolean;
  external 'GetFileVersionInfoW@version.dll stdcall';
function ExitVersionValue(Buffer, Key: String; var Value: NativeUInt; var Length: LongWord): Boolean;
  external 'VerQueryValueW@version.dll stdcall';
procedure ExitCopyMemory(Destination: String; Source, Size: NativeUInt);
  external 'RtlMoveMemory@kernel32.dll stdcall';

function DingGeTProductName(FileName: String): String;
var
  Size, Ignored, Length: LongWord;
  Buffer: String;
  Value: NativeUInt;
begin
  Result := '';
  Size := ExitVersionSize(FileName, Ignored);
  if (Size = 0) or (Size > 1048576) then Exit;
  Buffer := StringOfChar(#0, (Size + 1) div 2);
  if not ExitVersionInfo(FileName, 0, Size, Buffer) then Exit;
  if not ExitVersionValue(Buffer, '\StringFileInfo\040904e4\ProductName', Value, Length) then Exit;
  if (Length < 1) or (Length > 256) then Exit;
  Result := StringOfChar(#0, Length);
  ExitCopyMemory(Result, Value, Length * 2);
  SetLength(Result, Length - 1);
end;

function IsDingGeT(ProcessId, CurrentSession: LongWord; var ImagePath: String): Boolean;
var
  Handle: THandle;
  SessionId, Size: LongWord;
  Product: String;
begin
  Result := False;
  if not ExitGetSessionId(ProcessId, SessionId) then Exit;
  if SessionId <> CurrentSession then Exit;
  Handle := ExitOpenProcess($1000, False, ProcessId);
  if Handle = 0 then Exit;
  try
    Size := 32768;
    ImagePath := StringOfChar(#0, Size);
    if not ExitQueryPath(Handle, 0, ImagePath, Size) then Exit;
    SetLength(ImagePath, Size);
    if CompareText(ExtractFileName(ImagePath), 'screen_clip_win.exe') <> 0 then Exit;
    Product := DingGeTProductName(ImagePath);
    if (Product <> 'ScreenClip') and (Product <> '定格T') then Exit;
#ifdef InstallerTest
    { Test installers may only close processes in their explicitly isolated root. }
    if Pos(Lowercase(AddBackslash(ExpandConstant('{param:TestRoot|{app}}'))), Lowercase(ImagePath)) <> 1 then Exit;
#endif
    Result := True;
  finally
    ExitCloseHandle(Handle);
  end;
end;

function StopDingGeT(Window: HWND; ProcessId: LongWord; ImagePath: String): String;
var
  Handle: THandle;
  ActualPath: String;
  Size: LongWord;
begin
  Result := '';
  Handle := ExitOpenProcess($101001, False, ProcessId); { query, synchronize, terminate }
  if Handle = 0 then begin
    Result := '无法自动退出定格T。请使用与定格T相同的运行权限启动安装程序。';
    Exit;
  end;
  try
    if ExitWait(Handle, 0) = 0 then Exit;
    Size := 32768;
    ActualPath := StringOfChar(#0, Size);
    if not ExitQueryPath(Handle, 0, ActualPath, Size) then begin
      Result := '无法核实定格T进程，请重试安装。'; Exit;
    end;
    SetLength(ActualPath, Size);
    if CompareText(ActualPath, ImagePath) <> 0 then begin
      Result := '定格T运行状态已变化，请重试安装。'; Exit;
    end;
    Log(Format('Closing DingGeT PID %d: %s', [ProcessId, ImagePath]));
    PostMessage(Window, $0011, 0, 1); { WM_QUERYENDSESSION / ENDSESSION_CLOSEAPP }
    PostMessage(Window, $0016, 1, 1); { WM_ENDSESSION confirmed }
    if ExitWait(Handle, 1200) <> 0 then begin
      Log(Format('Legacy DingGeT PID %d did not exit; terminating verified instance.', [ProcessId]));
      if not ExitTerminate(Handle, 0) then begin
        Result := '自动退出定格T失败，安装尚未开始，请重试。'; Exit;
      end;
      if ExitWait(Handle, 5000) <> 0 then Result := '定格T尚未退出，安装已暂停，请重试。';
    end;
  finally
    ExitCloseHandle(Handle);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Window, NextWindow: HWND;
  ProcessId, CurrentSession: LongWord;
  ImagePath: String;
begin
  Result := '';
  if not ExitGetSessionId(ExitCurrentProcessId(), CurrentSession) then begin
    Result := '无法检查当前运行会话，请重试安装。'; Exit;
  end;
  Window := ExitFindWindow(0, 0, 'FLUTTER_RUNNER_WIN32_WINDOW', 0);
  while Window <> 0 do begin
    NextWindow := ExitFindWindow(0, Window, 'FLUTTER_RUNNER_WIN32_WINDOW', 0);
    ExitGetProcessId(Window, ProcessId);
    if IsDingGeT(ProcessId, CurrentSession, ImagePath) then begin
      if not WizardIsTaskSelected('closeapp') then begin
        Result := '定格T正在运行。请勾选“安装前自动退出正在运行的定格T”后继续。'; Exit;
      end;
      Result := StopDingGeT(Window, ProcessId, ImagePath);
      if Result <> '' then Exit;
      { Restart traversal because an exiting process can destroy other windows. }
      NextWindow := ExitFindWindow(0, 0, 'FLUTTER_RUNNER_WIN32_WINDOW', 0);
    end;
    Window := NextWindow;
  end;
end;
