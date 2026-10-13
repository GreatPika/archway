const
  OwnerKey = 'Software\Archway\Installer';
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{A94B4B61-D646-488F-B105-6906974DE57C}_is1';
type
  { WIN32_FIND_DATAW: eleven DWORDs followed by 260 + 14 UTF-16 code units.
    No pointers or managed strings; the layout is 592 bytes on Win32 and Win64. }
  TDirectoryFindData = record
    Attributes: Cardinal;
    CreationTime, LastAccessTime, LastWriteTime: TFileTime;
    SizeHigh, SizeLow, Reserved0, Reserved1: Cardinal;
    FileName: array[0..259] of Char;
    AlternateFileName: array[0..13] of Char;
  end;
var
  PreviousFiles, IncomingFiles: TArrayOfString;
  WasOwned, LifecycleFailed: Boolean;
  LifecycleError: String;

function GetFileAttributesW(Name: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function ExpandEnvironmentStringsW(Source, Dest: String; Size: Cardinal): Cardinal;
  external 'ExpandEnvironmentStringsW@kernel32.dll stdcall';

function FindFirstFileW(Name: String; var Data: TDirectoryFindData): THandle;
  external 'FindFirstFileW@kernel32.dll stdcall';
function FindNextFileW(Handle: THandle; var Data: TDirectoryFindData): BOOL;
  external 'FindNextFileW@kernel32.dll stdcall';
function CloseFindHandle(Handle: THandle): BOOL;
  external 'FindClose@kernel32.dll stdcall';

function InstallRoot: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\Archway');
end;

function CommandDir: String;
begin
  Result := InstallRoot + '\bin\windows-x64';
end;

procedure Require(Value: Boolean; MessageText: String);
begin
  if not Value then RaiseException(MessageText);
end;

procedure NoReparse(Path: String);
var
  Attributes, ErrorCode: Cardinal;
  Parent: String;
begin
  if Path = '' then Exit;
  Parent := ExtractFileDir(Path);
  { Check ancestors before a lookup can resolve a child through them. }
  if Parent <> Path then NoReparse(Parent);
  Attributes := GetFileAttributesW(Path);
  if Attributes = $FFFFFFFF then begin
    ErrorCode := DLLGetLastError;
    { Prospective installation paths may not exist yet. }
    Require((ErrorCode = 2) or (ErrorCode = 3),
      'Cannot inspect installation path: ' + Path + ' (' + IntToStr(ErrorCode) + ')');
  end else
    Require((Attributes and $400) = 0,
      'Refusing reparse-point installation path: ' + Path);
end;

procedure NoReparseTree(Directory: String);
var
  Data: TDirectoryFindData;
  Handle: THandle;
  Attributes, ErrorCode: Cardinal;
  Name, Child: String;
  I: Integer;
begin
  NoReparse(Directory);
  Attributes := GetFileAttributesW(Directory);
  ErrorCode := DLLGetLastError;
  Require((Attributes <> $FFFFFFFF) and ((Attributes and $10) <> 0),
    'Cannot inspect installed directory: ' + Directory + ' (' + IntToStr(ErrorCode) + ')');
  Require(SizeOf(Data) = 592, 'Unsupported directory enumeration layout.');
  Handle := FindFirstFileW(Directory + '\*', Data);
  if Handle = THandle(-1) then begin
    ErrorCode := DLLGetLastError;
    Require(ErrorCode = 2,
      'Cannot enumerate installed directory: ' + Directory + ' (' + IntToStr(ErrorCode) + ')');
    Exit;
  end;
  try
    while True do begin
      Name := '';
      I := 0;
      while I < 260 do begin
        if Data.FileName[I] = #0 then Break;
        Name := Name + Data.FileName[I];
        I := I + 1;
      end;
      Require((I > 0) and (I < 260), 'Invalid directory entry name.');
      if (Name <> '.') and (Name <> '..') then begin
        Child := Directory + '\' + Name;
        Require((Data.Attributes and $400) = 0,
          'Refusing reparse-point installation entry: ' + Child);
        if (Data.Attributes and $10) <> 0 then NoReparseTree(Child);
      end;
      if not FindNextFileW(Handle, Data) then begin
        ErrorCode := DLLGetLastError;
        Require(ErrorCode = 18,
          'Cannot finish installed directory enumeration: ' + Directory +
          ' (' + IntToStr(ErrorCode) + ')');
        Break;
      end;
    end;
  finally
    Require(CloseFindHandle(Handle), 'Cannot close directory enumeration.');
  end;
end;

function OwnedRoot: Boolean;
var
  Root: String;
begin
  Result := RegQueryStringValue(HKCU, OwnerKey, 'Root', Root);
  if Result then Result := (CompareText(Root, InstallRoot) = 0) and
    RegKeyExists(HKCU, UninstallKey) and
    FileExists(InstallRoot + '\.archway-owned-files.txt');
end;

function RawPath: String;
begin
  Result := '';
  if RegValueExists(HKCU, 'Environment', 'Path') then
    Require(RegQueryStringValue(HKCU, 'Environment', 'Path', Result),
      'User PATH is unreadable or is not a string. No changes made.');
end;

function Comparable(Token: String): String;
var
  Expanded: String;
  Needed: Cardinal;
begin
  Result := Trim(Token);
  if (Length(Result) >= 2) and (Result[1] = '"') and
      (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
  Needed := ExpandEnvironmentStringsW(Result, '', 0);
  Require(Needed > 0, 'Cannot interpret PATH for collision checks.');
  SetLength(Expanded, Needed);
  Require(ExpandEnvironmentStringsW(Result, Expanded, Needed) = Needed,
    'Environment changed during PATH checks. Please retry.');
  SetLength(Expanded, Needed - 1);
  Result := RemoveBackslashUnlessRoot(Expanded);
end;

function TakeToken(const Value: String; var Position: Integer): String;
var
  Start: Integer;
begin
  Start := Position;
  while Position <= Length(Value) do begin
    if Value[Position] = ';' then Break;
    Position := Position + 1;
  end;
  Result := Copy(Value, Start, Position - Start);
  Position := Position + 1;
end;

function HasCommandToken(const Value: String): Boolean;
var
  Position: Integer;
begin
  Result := False;
  Position := 1;
  while Position <= Length(Value) + 1 do
    if CompareText(Comparable(TakeToken(Value, Position)), CommandDir) = 0 then begin
      Result := True;
      Exit;
    end;
end;

procedure CheckCommands(const Value: String);
var
  Position: Integer;
  Dir: String;
begin
  Position := 1;
  while Position <= Length(Value) + 1 do begin
    Dir := Comparable(TakeToken(Value, Position));
    if (Dir <> '') and not (WasOwned and (CompareText(Dir, CommandDir) = 0)) then
      Require(not FileExists(AddBackslash(Dir) + 'archway.exe') and
        not FileExists(AddBackslash(Dir) + 'archway.cmd') and
        not FileExists(AddBackslash(Dir) + 'archway.bat') and
        not FileExists(AddBackslash(Dir) + 'archway.com'),
        'Another archway command exists in PATH: ' + Dir);
  end;
end;

function EntryName(const Entry: String): String;
begin
  Require((Length(Entry) > 65) and (Entry[65] = #9),
    'Invalid owned-file inventory.');
  Result := Copy(Entry, 66, Length(Entry));
  Require((Pos('\..\', '\' + Result + '\') = 0) and (Pos(':', Result) = 0) and
    (Pos('/', Result) = 0) and (Result[1] <> '\'),
    'Unsafe owned-file inventory path.');
end;

function InventoryContains(const Entries: TArrayOfString; const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to GetArrayLength(Entries) - 1 do
    if CompareText(EntryName(Entries[I]), Name) = 0 then begin
      Result := True;
      Exit;
    end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  I: Integer;
  Name, PathValue: String;
begin
  Result := '';
  try
    Require(CompareText(ExpandConstant('{app}'), InstallRoot) = 0,
      'Archway only supports its fixed per-user installation directory.');
    NoReparse(InstallRoot);
    WasOwned := OwnedRoot;
    Require(WasOwned or not RegKeyExists(HKCU, OwnerKey),
      'Unverified installer ownership state exists; refusing to adopt it.');
    Require(not DirExists(InstallRoot) or WasOwned,
      'Installation directory already exists and is not owned by this installer.');
    Require(not FileExists(InstallRoot), 'Installation path is an existing file.');
    if WasOwned then NoReparseTree(InstallRoot);
    PathValue := RawPath;
    CheckCommands(GetEnv('PATH'));
    CheckCommands(PathValue);
    if WasOwned then
      Require(LoadStringsFromFile(InstallRoot + '\.archway-owned-files.txt', PreviousFiles),
        'Cannot read previous owned-file inventory.');
    for I := 0 to GetArrayLength(PreviousFiles) - 1 do begin
      Name := EntryName(PreviousFiles[I]);
      NoReparse(InstallRoot + '\' + Name);
    end;
    ExtractTemporaryFile('owned-files.txt');
    Require(LoadStringsFromFile(ExpandConstant('{tmp}\owned-files.txt'), IncomingFiles),
      'Cannot read incoming owned-file inventory.');
    for I := 0 to GetArrayLength(IncomingFiles) - 1 do begin
      Name := EntryName(IncomingFiles[I]);
      NoReparse(InstallRoot + '\' + Name);
      Require(not FileExists(InstallRoot + '\' + Name) or
        InventoryContains(PreviousFiles, Name), 'Refusing to replace foreign file: ' + Name);
    end;
  except
    Result := GetExceptionMessage;
  end;
end;

procedure RegisterCommand;
var
  Value, NewValue: String;
begin
  Value := RawPath;
  { Never adopt a token that was present before installation. Preserve upgrade
    ownership independently of the currently edited user PATH. }
  if HasCommandToken(Value) then Exit;
  NewValue := Value;
  if NewValue <> '' then NewValue := NewValue + ';';
  NewValue := NewValue + CommandDir;
  { Inno preserves REG_EXPAND_SZ when writing a pre-existing expandable value;
    existing REG_SZ stays REG_SZ. No expansion, fixed buffer or setx involved. }
  Require(RegWriteStringValue(HKCU, 'Environment', 'Path', NewValue),
    'Could not register the Archway command in user PATH.');
  if not RegWriteStringValue(HKCU, OwnerKey, 'PathToken', CommandDir) then begin
    { Do not restore a snapshot over concurrent unrelated edits. }
    RaiseException('PATH was updated but ownership could not be saved. ' +
      'Keep this message: automatic PATH removal will not be attempted.');
  end;
end;

procedure CompleteInstallation;
var
  I: Integer;
  Name, FullName: String;
begin
  Require(RegWriteStringValue(HKCU, OwnerKey, 'Root', InstallRoot),
    'Could not save installation ownership.');
  RegisterCommand;
  { Remove only stale bytes proven to belong to the previous payload, after
    standard Inno installation succeeds. Never delete a whole mixed root. }
  for I := 0 to GetArrayLength(PreviousFiles) - 1 do begin
    Name := EntryName(PreviousFiles[I]);
    if not InventoryContains(IncomingFiles, Name) then begin
      FullName := InstallRoot + '\' + Name;
      NoReparse(FullName);
      if FileExists(FullName) then
        if CompareText(GetSHA256OfFile(FullName), Copy(PreviousFiles[I], 1, 64)) = 0 then
          Require(DeleteFile(FullName), 'Could not remove stale owned file: ' + Name);
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then Exit;
  { A post-install exception alone does not guarantee a failing Setup exit. }
  LifecycleFailed := True;
  try
    CompleteInstallation;
    LifecycleFailed := False;
  except
    LifecycleError := GetExceptionMessage;
    Log('Archway installation incomplete: ' + LifecycleError);
    SuppressibleMsgBox('Archway installation incomplete: ' + LifecycleError,
      mbError, MB_OK, IDOK);
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if LifecycleFailed then Result := 20 else Result := 0;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and LifecycleFailed then
    WizardForm.FinishedLabel.Caption := 'Archway installation incomplete. ' + LifecycleError;
end;

procedure RemoveOwnedPath;
var
  Value, Token, Item, Updated: String;
  Position, Start, FoundStart, FoundEnd, Matches: Integer;
begin
  if not RegQueryStringValue(HKCU, OwnerKey, 'PathToken', Token) then Exit;
  Require(Token = CommandDir, 'Unexpected PATH ownership record; preserving PATH.');
  Value := RawPath;
  Position := 1;
  Matches := 0;
  FoundStart := 0;
  FoundEnd := 0;
  while Position <= Length(Value) + 1 do begin
    Start := Position;
    Item := TakeToken(Value, Position);
    if Item = Token then begin
      Matches := Matches + 1;
      FoundStart := Start;
      FoundEnd := Position - 2;
    end;
  end;
  if Matches > 1 then begin
    RaiseException('Duplicate owned PATH tokens are ambiguous; PATH was preserved.');
  end;
  if Matches = 1 then begin
    if FoundStart > 1 then FoundStart := FoundStart - 1
    else if FoundEnd < Length(Value) then FoundEnd := FoundEnd + 1;
    { Two Copy results can infer an ANSI concatenation in Pascal Script.
      Delete from the typed Unicode String without narrowing unrelated tokens. }
    Updated := Value;
    Delete(Updated, FoundStart, FoundEnd - FoundStart + 1);
    Require(RegWriteStringValue(HKCU, 'Environment', 'Path', Updated),
      'Cannot remove owned PATH token; uninstall stopped.');
  end;
  Require(RegDeleteValue(HKCU, OwnerKey, 'PathToken'), 'Cannot clear PATH ownership.');
end;

function InitializeUninstall: Boolean;
var
  Entries: TArrayOfString;
  I: Integer;
begin
  Result := False;
  try
    NoReparse(InstallRoot);
    Require(OwnedRoot, 'Cannot verify installer ownership. Uninstall stopped.');
    NoReparseTree(InstallRoot);
    Require(LoadStringsFromFile(InstallRoot + '\.archway-owned-files.txt', Entries),
      'Cannot read installed ownership inventory.');
    for I := 0 to GetArrayLength(Entries) - 1 do
      NoReparse(InstallRoot + '\' + EntryName(Entries[I]));
    RawPath;
    Result := True;
  except
    SuppressibleMsgBox(GetExceptionMessage, mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    try
      NoReparseTree(InstallRoot);
      RemoveOwnedPath;
    except
      SuppressibleMsgBox(GetExceptionMessage, mbError, MB_OK, IDOK);
      { Abort in usUninstall is explicitly documented to stop the uninstaller. }
      Abort;
    end;
  end;
  if CurUninstallStep = usPostUninstall then begin
    RegDeleteValue(HKCU, OwnerKey, 'Root');
    RegDeleteKeyIfEmpty(HKCU, OwnerKey);
  end;
end;
