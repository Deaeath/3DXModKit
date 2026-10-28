; 3dxGC - per-user Windows installer.
;
; Built by build\Build-Release.ps1, which passes the version and the staged
; release folder:
;
;   ISCC /DAppVersion=1.6.0 /DStageDir=<repo>\dist\stage\3DXModKit build\3dxGC.iss
;
; Installs into %LOCALAPPDATA%\Programs\3dxGC without admin rights, so Setup
; never shows a UAC prompt. The panel updates an installed copy by running
; the next release's Setup silently (/visible=1 and /noelevate=1 tell Setup
; how to reopen it). config\, logs\ and backups\ belong to the user: Setup
; never ships them, and the uninstaller asks before deleting settings.
;
; /DTestBuild makes a build that installs next to a real copy without
; touching it: its own Apps entry, shortcuts, startup entry, window title
; and exit signal.

#ifndef AppVersion
  #error Pass /DAppVersion=x.y.z - build\Build-Release.ps1 does
#endif
#ifndef StageDir
  #error Pass /DStageDir=<staged 3DXModKit folder> - build\Build-Release.ps1 does
#endif

; Also set by gui\Start-Gui.ps1 on its window: the taskbar matches the two.
#define AppUserModelId "Deaeath.3dxGC"
#ifdef TestBuild
  #define AppGuid "B4E7C2A1-9F3D-4E58-A6C1-7D2B8E4F1A91"
  #define AppTitle "3dxGC Test"
  #define RunValueName "3dxGC-test"
  #define PanelTitle "3dxGC-test-panel"
  #define ExitSignal "Local\3dxGC-Exit-test"
#else
  ; The module manifest's GUID. Get-ModKitInstall and gui\Apply-Update.ps1
  ; find the Apps & Features entry by it ({AppGuid}_is1).
  #define AppGuid "B4E7C2A1-9F3D-4E58-A6C1-7D2B8E4F1A90"
  #define AppTitle "3dxGC"
  ; The panel's own "Start with Windows" value.
  #define RunValueName "3dxGC"
  ; gui\MainWindow.xaml's Title, and the event gui\Start-Gui.ps1 opens.
  #define PanelTitle "3dxGC - 3DXChat Control Panel"
  #define ExitSignal "Local\3dxGC-Exit"
#endif

[Setup]
AppId={{{#AppGuid}}
AppName={#AppTitle}
AppVersion={#AppVersion}
AppVerName={#AppTitle} {#AppVersion}
AppPublisher=Deaeath
AppPublisherURL=https://github.com/Deaeath/3DXModKit
AppSupportURL=https://github.com/Deaeath/3DXModKit/issues
AppUpdatesURL=https://github.com/Deaeath/3DXModKit/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName=3dxGC
VersionInfoDescription=3dxGC Setup
PrivilegesRequired=lowest
DefaultDirName={autopf}\3dxGC
DisableProgramGroupPage=yes
UninstallDisplayName={#AppTitle}
UninstallDisplayIcon={app}\3dxGC.exe
SetupIconFile=..\gui\3dxGC.ico
WizardStyle=modern dynamic
WizardSmallImageFile=wizard-small.png
OutputDir=..\dist
OutputBaseFilename=3dxGC-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; A running panel is closed by [Code] below; Restart Manager can't see it.
CloseApplications=no

[Tasks]
Name: autostart; Description: "Start 3dxGC with &Windows (it waits in the system tray)"
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; src\ and gui\ hold only the app's own code, so a file a release dropped
; can't linger there and still get loaded.
Type: filesandordirs; Name: "{app}\src"
Type: filesandordirs; Name: "{app}\gui"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Excludes: ".git*"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppTitle}"; Filename: "{app}\3dxGC.exe"; Comment: "Keeps 3DXChat's memory in check"; AppUserModelID: "{#AppUserModelId}"
Name: "{autodesktop}\{#AppTitle}"; Filename: "{app}\3dxGC.exe"; Comment: "Keeps 3DXChat's memory in check"; AppUserModelID: "{#AppUserModelId}"; Tasks: desktopicon

[Run]
; Setup closed a running panel to update it, so it comes back the way it was.
Filename: "{app}\3dxGC.exe"; Parameters: "{code:RelaunchParams}"; Flags: nowait; Check: WasRunning
Filename: "{app}\3dxGC.exe"; Description: "Open 3dxGC now"; Flags: postinstall nowait skipifsilent; Check: not WasRunning

[Code]
const
  PanelTitle = '{#PanelTitle}';
  ExitSignalName = '{#ExitSignal}';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  RunValue = '{#RunValueName}';
  EVENT_MODIFY_STATE = $0002;
  SYNCHRONIZE = $00100000;

var
  PanelWasRunning: Boolean;
  TasksPreset: Boolean;
  ImportedFrom: String;
  DeleteSettings: Boolean;

function OpenEvent(DesiredAccess: DWORD; InheritHandle: BOOL; Name: String): THandle;
  external 'OpenEventW@kernel32.dll stdcall';
function SetEvent(Event: THandle): BOOL;
  external 'SetEvent@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

function WasRunning: Boolean;
begin
  Result := PanelWasRunning;
end;

{ How the panel Setup closed comes back: in the tray unless it was on
  screen (/visible=1), told what it was updated to, and - for one that ran
  without administrator (/noelevate=1) - without a UAC prompt. }
function RelaunchParams(Param: String): String;
begin
  Result := '-JustUpdated {#AppVersion}';
  if ExpandConstant('{param:visible|0}') <> '1' then Result := '-Minimized ' + Result;
  if ExpandConstant('{param:noelevate|0}') = '1' then Result := '-noelevate ' + Result;
end;

function PanelOpen: Boolean;
begin
  Result := FindWindowByWindowName(PanelTitle) <> 0;
end;

{ Closes a running control panel the way its tray menu's Exit does - governor
  stopped, caps lifted - so its files can be replaced or removed. 1.6.0 and
  later listen for the exit signal. An older panel running as administrator
  can't be closed from here, so the user is asked to. }
function ClosePanel: Boolean;
var
  Signal: THandle;
  I: Integer;
begin
  Result := True;
  if not PanelOpen then Exit;
  PanelWasRunning := True;

  Signal := OpenEvent(EVENT_MODIFY_STATE or SYNCHRONIZE, False, ExitSignalName);
  if Signal <> 0 then
  begin
    SetEvent(Signal);
    CloseHandle(Signal);
    { it looks every 2 seconds, then stops the governor }
    for I := 1 to 75 do
    begin
      if not PanelOpen then Break;
      Sleep(200);
    end;
  end;

  while PanelOpen do
    if SuppressibleMsgBox('3dxGC is running. Right-click its icon in the system tray (by the clock), choose Exit 3dxGC, then click OK.',
         mbInformation, MB_OKCANCEL, IDCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;

  { the window goes just before the process does }
  Sleep(1000);
end;

{ --- Settings from a copy unpacked from the zip --------------------------- }

function IsOldCopy(const Dir: String): Boolean;
begin
  Result := FileExists(Dir + '\3DXModKit.psd1') and DirExists(Dir + '\config') and
    (CompareText(Dir, ExpandConstant('{app}')) <> 0);
end;

{ Release zips unpack to 3DXModKit-vX\3DXModKit, or straight to 3DXModKit.
  Folders come back in name order, so the last one kept is the highest
  version. }
procedure ScanFolder(const Parent: String; var Found: String);
var
  Rec: TFindRec;
begin
  if not FindFirst(Parent + '\3DXModKit*', Rec) then Exit;
  try
    repeat
      if Rec.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
      begin
        if IsOldCopy(Parent + '\' + Rec.Name) then Found := Parent + '\' + Rec.Name;
        if IsOldCopy(Parent + '\' + Rec.Name + '\3DXModKit') then Found := Parent + '\' + Rec.Name + '\3DXModKit';
      end;
    until not FindNext(Rec);
  finally
    FindClose(Rec);
  end;
end;

{ The copy its "start with Windows" entry points at ("<folder>\3dxGC.bat"
  -Minimized), else one in Downloads, on the Desktop or in Documents. }
function FindOldCopy: String;
var
  Cmd: String;
  P: Integer;
begin
  Result := '';
  if RegQueryStringValue(HKCU, RunKey, RunValue, Cmd) and (Copy(Cmd, 1, 1) = '"') then
  begin
    Delete(Cmd, 1, 1);
    P := Pos('"', Cmd);
    if (P > 0) and IsOldCopy(ExtractFileDir(Copy(Cmd, 1, P - 1))) then
    begin
      Result := ExtractFileDir(Copy(Cmd, 1, P - 1));
      Exit;
    end;
  end;
  ScanFolder(ExpandConstant('{userdocs}'), Result);
  ScanFolder(ExpandConstant('{userdesktop}'), Result);
  ScanFolder(GetEnv('USERPROFILE') + '\Downloads', Result);
end;

{ Copies a folder's files and subfolders, never over a file already there. }
procedure CopyTree(const Source, Dest: String);
var
  Rec: TFindRec;
begin
  if not FindFirst(Source + '\*', Rec) then Exit;
  try
    ForceDirectories(Dest);
    repeat
      if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
      if Rec.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
        CopyTree(Source + '\' + Rec.Name, Dest + '\' + Rec.Name)
      else if not FileExists(Dest + '\' + Rec.Name) then
        FileCopy(Source + '\' + Rec.Name, Dest + '\' + Rec.Name, True);
    until not FindNext(Rec);
  finally
    FindClose(Rec);
  end;
end;

{ --- Setup --------------------------------------------------------------- }

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not ClosePanel then
    Result := '3dxGC is still running. Exit it from its tray icon, then run Setup again.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  App, Old: String;
  Autostart: Boolean;
begin
  App := ExpandConstant('{app}');
  if CurStep = ssInstall then
  begin
    { A first install picks up the settings of a copy run from the zip, so
      nobody sets their caps up twice. }
    if not DirExists(App + '\config') then
    begin
      Old := FindOldCopy;
      if Old <> '' then
      begin
        CopyTree(Old + '\config', App + '\config');
        if DirExists(Old + '\backups') then CopyTree(Old + '\backups', App + '\backups');
        ImportedFrom := Old;
      end;
    end;
  end
  else if CurStep = ssPostInstall then
  begin
    { A silent update has no tasks page, so it keeps what the panel's own
      "Start with Windows" box says rather than the first install's choice. }
    if WizardSilent and (WizardForm.PrevAppDir <> '') then
      Autostart := RegValueExists(HKCU, RunKey, RunValue)
    else
      Autostart := WizardIsTaskSelected('autostart');
    if Autostart then
      RegWriteStringValue(HKCU, RunKey, RunValue, '"' + App + '\3dxGC.exe" -Minimized')
    else
      RegDeleteValue(HKCU, RunKey, RunValue);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  OldHeight: Integer;
begin
  { The box shows what the panel's own "Start with Windows" says now: on for
    a first install, as it was for anyone who had 3dxGC before. }
  if (CurPageID = wpSelectTasks) and not TasksPreset then
  begin
    TasksPreset := True;
    if RegValueExists(HKCU, RunKey, RunValue) then
      WizardSelectTasks('autostart')
    else if (WizardForm.PrevAppDir <> '') or (FindOldCopy <> '') then
      WizardSelectTasks('!autostart');
  end;

  if (CurPageID = wpFinished) and (ImportedFrom <> '') then
  begin
    OldHeight := WizardForm.FinishedLabel.Height;
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
      'Your settings came over from your old 3dxGC folder. You can delete it now:' + #13#10 + ImportedFrom;
    WizardForm.FinishedLabel.AdjustHeight;
    WizardForm.RunList.Top := WizardForm.RunList.Top + WizardForm.FinishedLabel.Height - OldHeight;
  end;
end;

{ --- Uninstall ----------------------------------------------------------- }

function InitializeUninstall: Boolean;
begin
  Result := ClosePanel;
  if Result and not UninstallSilent then
    DeleteSettings := MsgBox('Also delete your 3dxGC settings?' + #13#10#13#10 +
      'Choose No to keep them for when you install 3dxGC again.',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
end;

procedure RemoveEntry(const Path: String);
begin
  if DirExists(Path) then DelTree(Path, True, True, True)
  else if FileExists(Path) then DeleteFile(Path);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  App, Cmd: String;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  App := ExpandConstant('{app}');

  { "Start with Windows", whether Setup or the panel turned it on }
  if RegQueryStringValue(HKCU, RunKey, RunValue, Cmd) and (Pos(Lowercase(App + '\'), Lowercase(Cmd)) > 0) then
    RegDeleteValue(HKCU, RunKey, RunValue);

  { The panel's own updates add files Setup's uninstall log doesn't list.
    Only the names a release ships are removed - never a whole folder the
    user might have pointed Setup at. }
  RemoveEntry(App + '\src');
  RemoveEntry(App + '\gui');
  RemoveEntry(App + '\mods');
  RemoveEntry(App + '\profiles');
  RemoveEntry(App + '\docs');
  RemoveEntry(App + '\runtime');
  RemoveEntry(App + '\logs');
  RemoveEntry(App + '\3DXModKit.psd1');
  RemoveEntry(App + '\3DXModKit.psm1');
  RemoveEntry(App + '\modkit.ps1');
  RemoveEntry(App + '\Install-ToToolkit.ps1');
  RemoveEntry(App + '\3dxGC.exe');
  RemoveEntry(App + '\3dxGC.bat');
  RemoveEntry(App + '\README.md');
  RemoveEntry(App + '\LICENSE');
  if DeleteSettings then
  begin
    RemoveEntry(App + '\config');
    RemoveEntry(App + '\backups');
  end;
  RemoveDir(App);
end;
