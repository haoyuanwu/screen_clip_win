#define AppVersion "1.1.0"
[Setup]
AppId={{E02AFC24-63BD-4C11-93AC-83D643717E92}
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
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoDescription=定格T截图安装程序
[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\定格T截图"; Filename: "{app}\screen_clip_win.exe"
Name: "{autodesktop}\定格T截图"; Filename: "{app}\screen_clip_win.exe"; Tasks: desktopicon
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "ScreenClip"; Flags: dontcreatekey uninsdeletevalue
[Run]
Filename: "{app}\screen_clip_win.exe"; Description: "启动定格T截图（默认开机启动，可在偏好设置中关闭）"; Flags: nowait postinstall skipifsilent
