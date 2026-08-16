#ifndef MyAppVersion
  #define MyAppVersion "1.2.4"
#endif

#define MyAppName "BStream Music"
#define MyAppPublisher "BryamContreras"
#define MyAppURL "https://github.com/BryamContreras/BStream-Music"
#define MyAppExeName "bstream_music.exe"
#define MyAppUserModelId "BStreamMusic.Desktop"
#define BundleDir "..\..\build\windows\x64\runner\Release"
#define AppIcon "..\..\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{8C7C6ED1-4C2B-4BBC-B4EA-7BF40D4A99B7}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\BStream Music
DefaultGroupName=BStream Music
DisableProgramGroupPage=yes
AllowNoIcons=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
OutputDir=..\..\dist
OutputBaseFilename=BStream-Music-{#MyAppVersion}-Windows-x64-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=yes
UsePreviousLanguage=yes
UsePreviousTasks=no
CloseApplications=yes
CloseApplicationsFilter={#MyAppExeName}
RestartApplications=no
SetupLogging=yes
ChangesAssociations=yes
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
english.AdditionalShortcuts=Additional shortcuts:
english.CreateDesktopShortcut=Create a &desktop shortcut
spanish.AdditionalShortcuts=Accesos directos adicionales:
spanish.CreateDesktopShortcut=Crear un acceso directo en el &escritorio

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopShortcut}"; GroupDescription: "{cm:AdditionalShortcuts}"; Flags: unchecked

[InstallDelete]
; Remove TikTok LIVE Python bridge files left by versions before the Dart client.
Type: filesandordirs; Name: "{app}\tools\tiktok-live-bridge"
Type: filesandordirs; Name: "{app}\tools\tiktok_live_bridge"
Type: files; Name: "{app}\tools\tiktok_live_bridge.exe"
Type: files; Name: "{app}\tools\tiktok-live-bridge.exe"
Type: files; Name: "{app}\scripts\tiktok_live_bridge.py"
Type: files; Name: "{app}\scripts\requirements-tiktok.txt"
Type: dirifempty; Name: "{app}\scripts"

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; AppUserModelID: "{#MyAppUserModelId}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; AppUserModelID: "{#MyAppUserModelId}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\bstreammusic"; ValueType: string; ValueName: ""; ValueData: "URL:BStream Music Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\bstreammusic"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\bstreammusic\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"",0"
Root: HKCU; Subkey: "Software\Classes\bstreammusic\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
