; Instalador de Heardy para Windows (W4 del plan de escritorio).
; Empaqueta la carpeta de `flutter build windows --release` en un único
; Heardy-Setup.exe, porque Flutter no produce un .exe suelto (Hallazgo 4) —
; copiar sólo heardy.exe sin sus DLL/`data/` no arranca.
;
; Reproducible:
;   1. flutter build windows --release
;   2. ISCC.exe windows\installer\heardy.iss
; El .exe resultante queda en build\windows\installer\Heardy-Setup.exe.
;
; AppId es un GUID fijo generado una sola vez para este proyecto — no
; cambiarlo nunca: es lo que permite que una instalación futura se detecte
; como una actualización en vez de una instalación paralela.
#define MyAppName "Heardy"
#define MyAppVersion "1.0.0"
#define MyAppExeName "heardy.exe"
#define MyReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{B96AA35E-22F7-4DEA-9D69-47F93994775D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build\windows\installer
OutputBaseFilename=Heardy-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
; Sin certificado de firma de código (~200 USD/año, ver Hallazgo 4):
; SmartScreen va a avisar "editor desconocido". Asumido, no un fallo.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Accesos directos adicionales:"

[Files]
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{group}\Desinstalar {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Abrir {#MyAppName}"; Flags: nowait postinstall skipifsilent
