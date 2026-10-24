param([string]$Executable = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Debug\screen_clip_win.exe'), [switch]$AllowParallel)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ClipSmoke {
 public delegate bool EnumProc(IntPtr hwnd, IntPtr parameter);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr parameter);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern uint RegisterClipboardFormat(string name);
 [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr handle);
 [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr handle);
 public static int[] PngDimensions() {
   var memory=GetClipboardData(RegisterClipboardFormat("PNG"));var data=GlobalLock(memory);
   if(data==IntPtr.Zero)throw new Exception("No PNG on clipboard");
   try {var b=new byte[24];Marshal.Copy(data,b,0,24);if(b[0]!=137 || b[1]!=80 || b[2]!=78 || b[3]!=71)throw new Exception("Invalid PNG");return new[]{(b[16]<<24)|(b[17]<<16)|(b[18]<<8)|b[19],(b[20]<<24)|(b[21]<<16)|(b[22]<<8)|b[23]};}finally{GlobalUnlock(memory);}
 }
 [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr owner);
 [DllImport("user32.dll")] public static extern bool CloseClipboard();
 [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
 [DllImport("gdi32.dll", EntryPoint="GetObjectW")] public static extern int GetObject(IntPtr bitmap,int size,out BitmapInfo info);
 [StructLayout(LayoutKind.Sequential)] public struct BitmapInfo { public int type,width,height,widthBytes; public ushort planes,bitsPixel; public IntPtr bits; }
 public static IntPtr FindMain(int pid) {
   IntPtr found=IntPtr.Zero;
   EnumWindows((hwnd,p)=>{uint owner;GetWindowThreadProcessId(hwnd,out owner);var name=new StringBuilder(256);GetClassName(hwnd,name,256);if(owner==pid && name.ToString()=="FLUTTER_RUNNER_WIN32_WINDOW"){found=hwnd;return false;}return true;},IntPtr.Zero);
   return found;
 }
 public static IntPtr FindChild(IntPtr parent) {
   IntPtr found=IntPtr.Zero;
   EnumChildWindows(parent,(hwnd,p)=>{found=hwnd;return false;},IntPtr.Zero);return found;
 }
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd,int index);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
 public static IntPtr FindPin(int pid) {
   IntPtr found=IntPtr.Zero;
   EnumWindows((hwnd,p)=>{uint owner;GetWindowThreadProcessId(hwnd,out owner);var name=new StringBuilder(256);GetClassName(hwnd,name,256);if(owner==pid && name.ToString()=="DingGeTPinnedImage"){found=hwnd;return false;}return true;},IntPtr.Zero);return found;
 }
 public static IntPtr Point(int x,int y) {return new IntPtr((y<<16)|(x&0xffff));}
}
"@
$resolvedExecutable = (Resolve-Path -LiteralPath $Executable).Path
if (-not $AllowParallel -and (Get-Process screen_clip_win -ErrorAction SilentlyContinue)) { throw 'Close the existing ScreenClip instance before running this smoke test.' }
$clipProcess = Start-Process -FilePath $resolvedExecutable -WindowStyle Hidden -PassThru
try {
 Start-Sleep -Milliseconds 1800
 $window = [ClipSmoke]::FindMain($clipProcess.Id)
 if ($window -eq [IntPtr]::Zero) { throw 'App window not created.' }
 if ([ClipSmoke]::IsWindowVisible($window)) { throw 'Resident app unexpectedly showed a home window.' }
 $sequence = [ClipSmoke]::GetClipboardSequenceNumber()
 [void][ClipSmoke]::PostMessage($window,0x0312,[IntPtr]71,[IntPtr]::Zero)
 Start-Sleep -Milliseconds 1500
 if (-not [ClipSmoke]::IsWindowVisible($window)) { throw 'Capture overlay did not appear.' }
 $child = [ClipSmoke]::FindChild($window)
 if ($child -eq [IntPtr]::Zero) { throw 'Flutter view missing.' }
 [void][ClipSmoke]::SetForegroundWindow($window)
 [void][ClipSmoke]::SendMessage($child,0x0200,[IntPtr]::Zero,[ClipSmoke]::Point(160,160))
 [void][ClipSmoke]::SendMessage($child,0x0201,[IntPtr]1,[ClipSmoke]::Point(160,160))
 for ($step=1;$step -le 12;$step++) {
   [void][ClipSmoke]::SendMessage($child,0x0200,[IntPtr]1,[ClipSmoke]::Point((160+30*$step),(160+20*$step)))
   Start-Sleep -Milliseconds 15
 }
 [void][ClipSmoke]::SendMessage($child,0x0202,[IntPtr]::Zero,[ClipSmoke]::Point(520,400))
 Start-Sleep -Milliseconds 400
 if ([ClipSmoke]::GetClipboardSequenceNumber() -ne $sequence) { throw 'Capture wrote to clipboard before selection confirmation.' }
 [void][ClipSmoke]::PostMessage($child,0x0100,[IntPtr]13,[IntPtr]0x001C0001)
 [void][ClipSmoke]::PostMessage($child,0x0101,[IntPtr]13,[IntPtr](-1071906815))
 Start-Sleep -Milliseconds 1200
 if ([ClipSmoke]::IsWindowVisible($window)) { throw 'Overlay did not dismiss after Enter.' }
 if ([ClipSmoke]::GetClipboardSequenceNumber() -eq $sequence) { throw 'Confirmation did not update clipboard.' }
 if (-not [ClipSmoke]::OpenClipboard([IntPtr]::Zero)) { throw 'Clipboard unavailable for validation.' }
 try {
   $dimensions = [ClipSmoke]::PngDimensions()
   $dpiScale = [ClipSmoke]::GetDpiForWindow($window) / 96.0
   $expectedWidth = [int](360 * $dpiScale)
   $expectedHeight = [int](240 * $dpiScale)
   if ($dimensions[0] -ne $expectedWidth -or $dimensions[1] -ne $expectedHeight) { throw "Unexpected clipboard dimensions: $($dimensions[0])x$($dimensions[1]); expected $($expectedWidth)x$($expectedHeight)" }

 } finally { [void][ClipSmoke]::CloseClipboard() }
 # A second capture is cancellable and must leave clipboard content unchanged.
 $sequence = [ClipSmoke]::GetClipboardSequenceNumber()
 [void][ClipSmoke]::PostMessage($window,0x0312,[IntPtr]71,[IntPtr]::Zero)
 Start-Sleep -Milliseconds 1200
 $child = [ClipSmoke]::FindChild($window)
 [void][ClipSmoke]::PostMessage($child,0x0100,[IntPtr]27,[IntPtr]0x00010001)
 [void][ClipSmoke]::PostMessage($child,0x0101,[IntPtr]27,[IntPtr](-1073676287))
 Start-Sleep -Milliseconds 500
 if ([ClipSmoke]::IsWindowVisible($window)) { throw 'Esc did not dismiss capture overlay.' }
 if ([ClipSmoke]::GetClipboardSequenceNumber() -ne $sequence) { throw 'Cancel changed clipboard.' }
 # Pin creates an independent topmost RAM image, without copying.
 $sequence = [ClipSmoke]::GetClipboardSequenceNumber()
 [void][ClipSmoke]::PostMessage($window,0x0312,[IntPtr]71,[IntPtr]::Zero)
 Start-Sleep -Milliseconds 1200
 $child = [ClipSmoke]::FindChild($window)
 [void][ClipSmoke]::SendMessage($child,0x0201,[IntPtr]1,[ClipSmoke]::Point(160,160))
 for ($step=1;$step -le 12;$step++) {
   [void][ClipSmoke]::SendMessage($child,0x0200,[IntPtr]1,[ClipSmoke]::Point((160+30*$step),(160+20*$step)))
   Start-Sleep -Milliseconds 15
 }
 [void][ClipSmoke]::SendMessage($child,0x0202,[IntPtr]::Zero,[ClipSmoke]::Point(520,400))
 Start-Sleep -Milliseconds 300
 [void][ClipSmoke]::PostMessage($child,0x0100,[IntPtr]70,[IntPtr]0x00210001)
 [void][ClipSmoke]::PostMessage($child,0x0101,[IntPtr]70,[IntPtr](-1071579135))
 Start-Sleep -Milliseconds 800
 $pin = [ClipSmoke]::FindPin($clipProcess.Id)
 if ($pin -eq [IntPtr]::Zero -or -not [ClipSmoke]::IsWindowVisible($pin)) { throw 'Pin image did not appear.' }
 if ([ClipSmoke]::IsWindowVisible($window)) { throw 'Capture overlay did not dismiss after pin.' }
 if (([ClipSmoke]::GetWindowLongPtr($pin,-20).ToInt64() -band 8) -eq 0) { throw 'Pin is not topmost.' }
 if ([ClipSmoke]::GetClipboardSequenceNumber() -ne $sequence) { throw 'Pin unexpectedly changed clipboard.' }
 $previousDpiContext = [ClipSmoke]::SetThreadDpiAwarenessContext([IntPtr](-4))
 $before = New-Object ClipSmoke+Rect
 [void][ClipSmoke]::GetWindowRect($pin,[ref]$before)
 [void][ClipSmoke]::SendMessage($pin,0x020A,[IntPtr](120 -shl 16),[IntPtr]::Zero)
 $after = New-Object ClipSmoke+Rect
 [void][ClipSmoke]::GetWindowRect($pin,[ref]$after)
 if (($after.right-$after.left) -le ($before.right-$before.left)) { throw 'Pin wheel resize failed.' }
 [void][ClipSmoke]::SendMessage($pin,0x0100,[IntPtr]67,[IntPtr]::Zero)
 # Copy via the custom toolbar; it preserves original PNG resolution.
 $pinScale = [ClipSmoke]::GetDpiForWindow($pin) / 96.0
 $copyX = ($after.right-$after.left) - [int](54*$pinScale)
 [void][ClipSmoke]::SendMessage($pin,0x0201,[IntPtr]1,[ClipSmoke]::Point($copyX,[int](17*$pinScale)))
 if ([ClipSmoke]::GetClipboardSequenceNumber() -eq $sequence) { throw 'Pin copy button did not copy.' }
 if (-not [ClipSmoke]::OpenClipboard([IntPtr]::Zero)) { throw 'Clipboard unavailable.' }
 try {
   $pinDimensions = [ClipSmoke]::PngDimensions()
   if ($pinDimensions[0] -ne $expectedWidth -or $pinDimensions[1] -ne $expectedHeight) { throw 'Pin copy lost source resolution.' }
 } finally { [void][ClipSmoke]::CloseClipboard() }
 [void][ClipSmoke]::SendMessage($pin,0x0100,[IntPtr]27,[IntPtr]::Zero)
 if ([ClipSmoke]::IsWindow($pin)) { throw 'Pin did not close on Esc.' }
 [void][ClipSmoke]::SetThreadDpiAwarenessContext($previousDpiContext)
 "PASS: pin appears topmost; overlay dismisses; clipboard unchanged until copy; wheel scales; copy keeps source resolution; Esc releases window."
 "PASS: hidden startup; native capture; selection exports $($dimensions[0])x$($dimensions[1]) source pixels at $dpiScale DPI scale; no pre-confirm copy; Enter copies and dismisses; Esc cancels without copying."
} finally {
 # Terminate only the process launched by this test; screenshots never touch disk.
 if (-not $clipProcess.HasExited) { $clipProcess.Kill(); $clipProcess.WaitForExit() }
}
