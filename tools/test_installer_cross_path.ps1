param(
 [string]$LegacyPackage = (Join-Path $PSScriptRoot '..\dist\ScreenClip-1.1.0-Windows-x64-Portable.zip'),
 [string]$Installer = (Join-Path $PSScriptRoot '..\dist\ScreenClip-InstallerVerification.exe')
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $projectRoot ('dist\installer-cross-path-test-' + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $testRoot 'NewInstall'
$processes = @()
$setupProcess = $null
function Run-TestInstaller([string]$Tasks, [string]$LogName) {
 $logPath = Join-Path $testRoot $LogName
 $script:setupProcess = Start-Process -FilePath (Resolve-Path -LiteralPath $Installer).Path -WindowStyle Hidden -PassThru -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="' + $target + '"'),('/TestRoot="' + $testRoot + '"'),('/TASKS="' + $Tasks + '"'),('/LOG="' + $logPath + '"'))
 if (-not $script:setupProcess.WaitForExit(30000)) { throw "Installer timed out. Log: $logPath" }
 return $script:setupProcess.ExitCode
}
try {
 foreach ($folder in @('OldInstall', 'Portable')) {
   $path = Join-Path $testRoot $folder
   Expand-Archive -LiteralPath (Resolve-Path -LiteralPath $LegacyPackage).Path -DestinationPath $path
   $processes += Start-Process -FilePath (Join-Path $path 'screen_clip_win.exe') -WorkingDirectory $path -WindowStyle Hidden -PassThru
 }
 Start-Sleep -Milliseconds 1700
 foreach ($app in $processes) { if ($app.HasExited) { throw 'Legacy test instance did not stay running.' } }
 # Not selecting automatic exit must not terminate any application or install files.
 $rejected = Run-TestInstaller 'desktopicon' 'unchecked.log'
 if ($rejected -eq 0) { throw 'Installer unexpectedly proceeded with automatic exit unchecked.' }
 foreach ($app in $processes) { if ($app.HasExited) { throw 'Unchecked automatic exit still terminated an app.' } }
 if (Test-Path -LiteralPath (Join-Path $target 'screen_clip_win.exe')) { throw 'Installer wrote files before resolving running instances.' }
 Write-Output 'PASS: unchecked automatic exit keeps both instances running and blocks installation.'
 $accepted = Run-TestInstaller 'closeapp' 'checked.log'
 if ($accepted -ne 0) { throw "Cross-directory installer failed: $accepted" }
 foreach ($app in $processes) { if (-not $app.WaitForExit(3000)) { throw 'A cross-directory instance was not closed.' } }
 $expected = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'build\windows\x64\runner\Release\screen_clip_win.exe') -Algorithm SHA256).Hash
 $actual = (Get-FileHash -LiteralPath (Join-Path $target 'screen_clip_win.exe') -Algorithm SHA256).Hash
 if ($expected -ne $actual) { throw 'Installed executable differs from current build.' }
 $log = Get-Content -LiteralPath (Join-Path $testRoot 'checked.log') -Raw
 if (($log | Select-String -Pattern 'Closing DingGeT PID' -AllMatches).Matches.Count -ne 2) { throw 'Installer did not log two verified exits.' }
 Write-Output 'PASS: checked automatic exit closes old-install and portable instances outside the target directory, then installs the current executable.'
 Write-Output "Logs: $testRoot"
} finally {
 if ($setupProcess -and -not $setupProcess.HasExited) { $setupProcess.Kill(); $setupProcess.WaitForExit() }
 foreach ($app in $processes) { if (-not $app.HasExited) { $app.Kill(); $app.WaitForExit() } }
}
