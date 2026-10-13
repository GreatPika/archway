; Build only with an explicitly provisioned Inno Setup 6 compiler on Windows.
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef OutputDir
  #error OutputDir must be a fresh absolute artifact directory
#endif
[Setup]
AppId={{A94B4B61-D646-488F-B105-6906974DE57C}
AppName=Archway
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Archway
DisableDirPage=yes
UsePreviousAppDir=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=archway-{#AppVersion}-windows-x64-unsigned
Compression=lzma2
SolidCompression=yes
ChangesEnvironment=yes
CloseApplications=no
RestartApplications=no
AllowCancelDuringInstall=no
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\bin\windows-x64\archway.exe
[Files]
#include "payload.iss"
Source: "owned-files.txt"; DestDir: "{app}"; DestName: ".archway-owned-files.txt"; Flags: ignoreversion
Source: "owned-files.txt"; Flags: dontcopy
[Code]
#include "lifecycle.iss"
