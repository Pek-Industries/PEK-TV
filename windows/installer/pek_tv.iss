; PEK TV for Windows - Inno Setup script. Built by windows/scripts/make-installer.sh (run by package.sh and the workflow):
;   ISCC /DAppVersion=2.2.7 /DArch=x64 /DSourceDir=<folder with pek_tv.exe and everything beside it> /DOutDir=<dist> pek_tv.iss
; One setup program per CPU type: PEK-TV-<version>-windows-<arch>-setup.exe (the in-app updater looks for that name, app_update.dart).
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #error SourceDir is not set
#endif
#ifndef OutDir
  #define OutDir "."
#endif

[Setup]
; Never change this id: it is how an update finds the copy it replaces.
AppId={{6E0A5D3C-4B1F-4C7A-9D28-5F3B7A91C4E2}
AppName=PEK TV
AppVersion={#AppVersion}
AppVerName=PEK TV {#AppVersion}
AppPublisher=PEK Industries
DefaultDirName={autopf}\PEK TV
DefaultGroupName=PEK TV
DisableProgramGroupPage=yes
DisableDirPage=auto
OutputDir={#OutDir}
OutputBaseFilename=PEK-TV-{#AppVersion}-windows-{#Arch}-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\pek_tv.exe
UninstallDisplayName=PEK TV
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Per user by default (no administrator prompt, and the app can update itself in its own folder); the wizard offers
; "install for all users" through the usual dialog.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes
RestartApplications=no
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\PEK TV"; Filename: "{app}\pek_tv.exe"; IconFilename: "{app}\pek_tv.exe"; AppUserModelID: "PEKIndustries.PEKTV"
Name: "{autodesktop}\PEK TV"; Filename: "{app}\pek_tv.exe"; IconFilename: "{app}\pek_tv.exe"; AppUserModelID: "PEKIndustries.PEKTV"; Tasks: desktopicon

[Run]
; After a normal install: the "Launch PEK TV" tick box on the last page. After an update from inside the app (silent, started
; with /relaunch=1): start the app again by itself.
Filename: "{app}\pek_tv.exe"; Description: "Launch PEK TV"; Flags: nowait postinstall skipifsilent
Filename: "{app}\pek_tv.exe"; Flags: nowait; Check: WantsRelaunch

[UninstallDelete]
; Files the app made inside its own folder (Python caches). The library, history and settings live in %LOCALAPPDATA%\PEK TV and are kept.
Type: filesandordirs; Name: "{app}"

[Code]
function WantsRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;
