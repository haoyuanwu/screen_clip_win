param([string]$Executable = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\screen_clip_win.exe'))
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class RealKeys {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int left,top,right,bottom;}
 [StructLayout(LayoutKind.Sequential)] public struct GuiInfo {public uint size,flags;public IntPtr active,focus,capture,menu,move,caret;public Rect caretRect;}
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd,StringBuilder name,int length);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code,uint kind);
 public static IntPtr FindMain(int pid) {
   IntPtr found=IntPtr.Zero;EnumWindows((hwnd,d)=>{uint owner;GetWindowThreadProcessId(hwnd,out owner);var c=new StringBuilder(256);GetClassName(hwnd,c,256);if(owner==pid && c.ToString()=="FLUTTER_RUNNER_WIN32_WINDOW"){found=hwnd;return false;}return true;},IntPtr.Zero);return found;
 }
 public static string FocusInfo(IntPtr window) {uint pid;var thread=GetWindowThreadProcessId(window,out pid);var info=new GuiInfo{size=(uint)Marshal.SizeOf(typeof(GuiInfo))};GetGUIThreadInfo(thread,ref info);var c=new StringBuilder(256);GetClassName(info.focus,c,256);uint foregroundPid;GetWindowThreadProcessId(GetForegroundWindow(),out foregroundPid);return "window="+window+" pid="+pid+" foreground="+GetForegroundWindow()+" foregroundPid="+foregroundPid+" focus="+info.focus+" class="+c;}
 [StructLayout(LayoutKind.Explicit,Size=40)] public struct KeyInput {
   [FieldOffset(0)] public uint type;[FieldOffset(8)] public ushort key;[FieldOffset(10)] public ushort scan;[FieldOffset(12)] public uint flags;
 }
 [DllImport("user32.dll",SetLastError=true)] public static extern uint SendInput(uint count,KeyInput[] inputs,int size);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from,uint to,bool attach);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hwnd);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string name,string title);
 [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hwnd,bool altTab);
 public static void Activate(IntPtr window) { SwitchToThisWindow(window,true); }
 public static void Key(IntPtr window,byte key) {
   uint wanted,actual;GetWindowThreadProcessId(window,out wanted);GetWindowThreadProcessId(GetForegroundWindow(),out actual);
   for(int attempt=0;attempt<10 && wanted!=actual;attempt++){System.Threading.Thread.Sleep(50);GetWindowThreadProcessId(GetForegroundWindow(),out actual);}
   if(wanted!=actual)throw new Exception("Refusing keyboard injection outside the test app. "+FocusInfo(window));
   var down=new KeyInput{type=1,key=key,scan=(ushort)MapVirtualKey(key,0)};
   if(SendInput(1,new[]{down},40)!=1)throw new Exception("SendInput down failed: "+Marshal.GetLastWin32Error());
   System.Threading.Thread.Sleep(60);down.flags=2;
   if(SendInput(1,new[]{down},40)!=1)throw new Exception("SendInput up failed: "+Marshal.GetLastWin32Error());
 }
}
"@
$original = New-Object RealKeys+Point
[void][RealKeys]::GetCursorPos([ref]$original)
$app = Start-Process -FilePath (Resolve-Path -LiteralPath $Executable).Path -WindowStyle Hidden -PassThru
try {
 Start-Sleep -Milliseconds 2200
 $window = [RealKeys]::FindMain($app.Id)
 if ($window -eq [IntPtr]::Zero) { throw 'Test window not found.' }
 foreach ($mode in @(71,73)) {
   [void][RealKeys]::PostMessage($window,0x0312,[IntPtr]$mode,[IntPtr]::Zero)
   for ($wait=0; $wait -lt 160 -and -not [RealKeys]::IsWindowVisible($window); $wait++) { Start-Sleep -Milliseconds 50 }
   if (-not [RealKeys]::IsWindowVisible($window)) { throw "Overlay $mode did not appear." }
   [RealKeys]::Activate($window)
   Start-Sleep -Milliseconds 150
   Write-Output "Mode ${mode}: $([RealKeys]::FocusInfo($window))"
   [void][RealKeys]::SetCursorPos(320,320)
   Start-Sleep -Milliseconds 150
   foreach ($step in @(@(87,0,-1),@(65,-1,0),@(83,0,1),@(68,1,0))) {
     $matched = $false
     for ($attempt=0; $attempt -lt 5 -and -not $matched; $attempt++) {
       [void][RealKeys]::SetCursorPos(320,320)
       Start-Sleep -Milliseconds 40
       $before = New-Object RealKeys+Point;[void][RealKeys]::GetCursorPos([ref]$before)
       [RealKeys]::Key($window,[byte]$step[0])
       Start-Sleep -Milliseconds 80
       $after = New-Object RealKeys+Point;[void][RealKeys]::GetCursorPos([ref]$after)
       $matched = $after.x -eq $before.x+$step[1] -and $after.y -eq $before.y+$step[2]
       if (-not $matched) { Start-Sleep -Milliseconds 200 }
     }
     if (-not $matched) { throw "Real WASD did not nudge cursor for key $($step[0]) or external mouse input interfered: $($before.x),$($before.y) -> $($after.x),$($after.y). $([RealKeys]::FocusInfo($window))" }
   }
   [RealKeys]::Key($window,27)
   Start-Sleep -Milliseconds 300
   if ([RealKeys]::IsWindowVisible($window)) { throw "Real Esc did not dismiss mode $mode." }
   Write-Output "PASS: mode $mode accepts real W/A/S/D nudges and Esc without directly sending keyboard window messages."
 }
} finally {
 [void][RealKeys]::SetCursorPos($original.x,$original.y)
 if (-not $app.HasExited) { $app.Kill();$app.WaitForExit() }
}
