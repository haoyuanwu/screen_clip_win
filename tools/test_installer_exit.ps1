param([string]$Executable = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\screen_clip_win.exe'))
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class InstallerExitProbe {
 public delegate bool EnumProc(IntPtr hwnd, IntPtr parameter);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 public static IntPtr Find(int pid) {
   IntPtr found=IntPtr.Zero;
   EnumWindows((hwnd,p)=>{uint owner;GetWindowThreadProcessId(hwnd,out owner);var name=new StringBuilder(256);GetClassName(hwnd,name,256);if(owner==pid && name.ToString()=="FLUTTER_RUNNER_WIN32_WINDOW"){found=hwnd;return false;}return true;},IntPtr.Zero);return found;
 }
}
"@
$app = Start-Process -FilePath (Resolve-Path -LiteralPath $Executable).Path -WindowStyle Hidden -PassThru
try {
 Start-Sleep -Milliseconds 1700
 $hwnd = [InstallerExitProbe]::Find($app.Id)
 if ($hwnd -eq [IntPtr]::Zero) { throw 'Test application window not found.' }
 [void][InstallerExitProbe]::SendMessage($hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
 if ($app.WaitForExit(300)) { throw 'Normal window close must keep the resident app running.' }
 $answer = [InstallerExitProbe]::SendMessage($hwnd,0x0011,[IntPtr]::Zero,[IntPtr]1)
 if ($answer -eq [IntPtr]::Zero) { throw 'Installer shutdown query was rejected.' }
 [void][InstallerExitProbe]::SendMessage($hwnd,0x0016,[IntPtr]::Zero,[IntPtr]1)
 if ($app.WaitForExit(300)) { throw 'Canceled installer shutdown unexpectedly exited the app.' }
 [void][InstallerExitProbe]::SendMessage($hwnd,0x0011,[IntPtr]::Zero,[IntPtr]1)
 [void][InstallerExitProbe]::SendMessage($hwnd,0x0016,[IntPtr]1,[IntPtr]1)
 if (-not $app.WaitForExit(5000)) { throw 'Confirmed installer shutdown did not exit the process.' }
 if ($app.ExitCode -ne 0) { throw "Application shutdown failed: $($app.ExitCode)" }
 Write-Output 'PASS: normal close stays resident; shutdown query accepted; canceled shutdown stays running; confirmed installer shutdown exits cleanly.'
} finally {
 if (-not $app.HasExited) { $app.Kill(); $app.WaitForExit() }
}
