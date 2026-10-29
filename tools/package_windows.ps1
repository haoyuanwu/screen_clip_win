param([switch]$SkipBuild, [string]$Compiler = '', [string]$RuntimeDirectory = '', [string]$Label = 'Preview')
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$previousLocation = Get-Location
try {
 Set-Location -LiteralPath $projectRoot
 $match = [regex]::Match((Get-Content -LiteralPath pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$')
 if (-not $match.Success) { throw 'Cannot read version from pubspec.yaml.' }
 $version = $match.Groups[1].Value
 if ($Label -notmatch '^[A-Za-z0-9-]+$') { throw 'Invalid package label.' }
 if (-not $SkipBuild) {
   flutter analyze
   if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
   flutter test
   if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
   flutter build windows --release
   if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
 }
 $release = Join-Path $projectRoot 'build\windows\x64\runner\Release'
 foreach ($name in @('screen_clip_win.exe','flutter_windows.dll','desktop_vision_plugin.dll','flutter_zxing.dll','file_selector_windows_plugin.dll','data\app.so')) {
   if (-not (Test-Path -LiteralPath (Join-Path $release $name))) { throw "Missing release dependency: $name" }
 }
 & python (Join-Path $PSScriptRoot 'argos\build.py') --destination (Join-Path $release 'argos')
 if ($LASTEXITCODE -ne 0) { throw 'Argos helper build failed.' }
 $builtVersion = (Get-Item -LiteralPath (Join-Path $release 'screen_clip_win.exe')).VersionInfo.FileVersion.Split('+')[0]
 if ($builtVersion -ne $version) { throw "Stale build: expected $version, found $builtVersion" }
 if (-not $RuntimeDirectory) {
   $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
   $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
   if (-not $visualStudio) { throw 'Visual Studio C++ runtime directory not found; pass -RuntimeDirectory.' }
   $runtime = Get-ChildItem -Path (Join-Path $visualStudio 'VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT') -Directory | Sort-Object FullName -Descending | Select-Object -First 1
   if (-not $runtime) { throw 'Visual C++ runtime files not found.' }
   $RuntimeDirectory = $runtime.FullName
 }
 Copy-Item -Path (Join-Path $RuntimeDirectory '*.dll') -Destination $release -Force
 if (-not $Compiler) {
   $candidates = @((Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'))
   $Compiler = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
 }
 if (-not $Compiler -or -not (Test-Path -LiteralPath $Compiler)) { throw 'Inno Setup compiler not found; pass -Compiler.' }
 New-Item -ItemType Directory -Path dist -Force | Out-Null
 $base = "ScreenClip-$version-Windows-x64-$Label"
 & $Compiler "/DAppVersion=$version" "/F$base-Setup" packaging\windows.iss
 if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
 $portable = Join-Path $projectRoot "dist\$base-Portable.zip"
 Compress-Archive -Path (Join-Path $release '*') -DestinationPath $portable -Force
 $assets = @((Join-Path $projectRoot "dist\$base-Setup.exe"),$portable)
 $checksums = foreach ($asset in $assets) {
   $hash = Get-FileHash -LiteralPath $asset -Algorithm SHA256
   $hash.Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($asset)
 }
 $checksums | Set-Content -LiteralPath "dist\SHA256SUMS-$version-$Label.txt" -Encoding ASCII
 $assets | ForEach-Object { Get-Item -LiteralPath $_ } | Select-Object Name,Length,FullName
} finally { Set-Location -LiteralPath $previousLocation.Path }
