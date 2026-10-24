param(
 [string]$LegacyPackage = (Join-Path $PSScriptRoot '..\dist\ScreenClip-1.1.0-Windows-x64-Portable.zip'),
 [string]$Installer = (Join-Path $PSScriptRoot '..\dist\ScreenClip-InstallerVerification.exe')
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$testDirectory = Join-Path $projectRoot ('dist\installer-upgrade-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
Expand-Archive -LiteralPath (Resolve-Path -LiteralPath $LegacyPackage).Path -DestinationPath $testDirectory
$executable = Join-Path $testDirectory 'screen_clip_win.exe'
$before = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
$expected = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'build\windows\x64\runner\Release\screen_clip_win.exe') -Algorithm SHA256).Hash
if ($before -eq $expected) { throw 'Use an older package to verify legacy shutdown compatibility.' }
$logPath = Join-Path $testDirectory 'installer.log'
$app = Start-Process -FilePath $executable -WorkingDirectory $testDirectory -WindowStyle Hidden -PassThru
$setupProcess = $null
try {
 Start-Sleep -Milliseconds 1700
 if ($app.HasExited) { throw 'Legacy test application did not stay running.' }
 $setupProcess = Start-Process -FilePath (Resolve-Path -LiteralPath $Installer).Path -WindowStyle Hidden -PassThru -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="' + $testDirectory + '"'),('/LOG="' + $logPath + '"'))
 if (-not $setupProcess.WaitForExit(45000)) { throw "Installer timed out. Log: $logPath" }
 if ($setupProcess.ExitCode -ne 0) { throw "Installer failed: $($setupProcess.ExitCode). Log: $logPath" }
 if (-not $app.WaitForExit(3000)) { throw 'Installer did not exit the legacy test application.' }
 if ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ne $expected) { throw 'Installed executable does not match current release build.' }
 Write-Output 'PASS: installer exits an uncooperative legacy instance and replaces its executable with the current build.'
 Write-Output "Installation log: $logPath"
} finally {
 if ($setupProcess -and -not $setupProcess.HasExited) { $setupProcess.Kill(); $setupProcess.WaitForExit() }
 if (-not $app.HasExited) { $app.Kill(); $app.WaitForExit() }
}
