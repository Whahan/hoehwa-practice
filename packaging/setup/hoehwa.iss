; 회화 연습 setup.exe (Inno Setup 6.7.4). 파일은 UTF-8 BOM (한글 문자열 때문에 꼭 BOM 이 있어야 한다).
;
;   ISCC.exe /DStageDir="<staging>\회화연습" /DAppVersion=1.5.0 /DOutDir="<출력 폴더>" [/DTestBuild=1] hoehwa.iss
;   (보통은 packaging\build_dist.ps1 이 부른다)
;
; 하는 일: 파일 풀기 -> install.ps1 (숨김) 실행 + 진행 파일(JSON)을 읽어 진행 막대에 보여 주기 -> 바로가기 -> 앱 실행.
; 질문 페이지는 모두 끈다 (환영, 폴더, 시작 메뉴 그룹, 준비, 끝). 관리자 권한을 요구하지 않는다.
; 폴더를 바꾸려면 화면이 아니라  hoehwa-practice-setup.exe /DIR="D:\회화연습"  처럼 인자로 준다.
; 큰 다운로드(파이썬 패키지, 음성 모델 등)는 이 파일이 하지 않는다: install.ps1 이 한다.
;
; TestBuild=1 (시험용): 다른 AppId·뮤텍스, 이름이 hoehwa-practice-setup-test.exe, 설치가 끝나도 앱을 실행하지 않는다.
;   바로가기와 지우기 경로를 환경변수로 돌릴 수 있다 (실제 바탕화면·시작 메뉴·LOCALAPPDATA 보호):
;     HOEHWA_TEST_SHORTCUT_DIR  : 이 폴더 아래 Desktop\, Programs\회화 연습\ 에 바로가기를 만든다 (없으면 바로가기를 만들지 않는다)
;     HOEHWA_TEST_LOCALAPPDATA  : 기본 설치 폴더 계산과 opencode 작업 폴더 삭제의 기준 (없으면 작업 폴더는 지우지 않는다)
;     HOEHWA_TEST_FALLBACK_DIR  : 경로가 길 때 쓰는 짧은 폴더 (없으면 C:\회화연습)
;     /PATHRULE=<LOCALAPPDATA 값> : 기본 폴더 계산 결과를 로그에 적고 바로 끝낸다 (설치하지 않음)
;   배포용(TestBuild=0)에는 이 환경변수를 읽는 코드가 아예 들어가지 않는다.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #error StageDir 를 /DStageDir="<staging>\회화연습" 로 알려 주세요.
#endif
#ifndef OutDir
  #define OutDir "out"
#endif
#ifndef TestBuild
  #define TestBuild 0
#endif
; 명령줄 /D 값은 글자일 수 있으니 0/1 정수(IsTest)로 바꿔 쓴다
#if Int(TestBuild, 0) != 0
  #define IsTest 1
#else
  #define IsTest 0
#endif

#ifndef Lzma
  #define Lzma "lzma2/max"
#endif

#if IsTest
  #define AppGuid "{{D56CB0A7-1AA7-41AA-89C9-B78E146F3367}"
  #define OutNameDefault "hoehwa-practice-setup-test"
  #define MutexName "HoehwaPracticeSetupTestMutex"
#else
  #define AppGuid "{{2806D5F9-42D5-4311-AB1F-482E52506E7D}"
  #define OutNameDefault "hoehwa-practice-setup"
  #define MutexName "HoehwaPracticeSetupMutex"
#endif

#ifndef OutBase
  #define OutBase OutNameDefault
#endif

[Setup]
AppId={#AppGuid}
AppName=회화 연습
AppVersion={#AppVersion}
AppVerName=회화 연습 {#AppVersion}
AppPublisher=Whahan
AppPublisherURL=https://github.com/Whahan/hoehwa-practice
AppSupportURL=https://github.com/Whahan/hoehwa-practice/issues
DefaultDirName={code:GetDefaultDir}
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableDirPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
DisableStartupPrompt=yes
ShowLanguageDialog=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename={#OutBase}
Compression={#Lzma}
SolidCompression=yes
WizardStyle=modern
SetupMutex={#MutexName}
CloseApplications=no
RestartApplications=no
UninstallDisplayIcon={app}\회화연습.exe
UninstallDisplayName=회화 연습
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName=회화 연습
VersionInfoDescription=회화 연습 설치 프로그램
VersionInfoCompany=Whahan

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Files]
; 앱 파일 전부. backend\config.json 은 따로: 이미 있으면 덮어쓰지 않는다 (다시 설치해도 사용자 설정이 그대로)
Source: "{#StageDir}\*"; DestDir: "{app}"; Excludes: "backend\config.json"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\backend\config.json"; DestDir: "{app}\backend"; Flags: onlyifdoesntexist
; 설치하는 동안 쓰는 정리 스크립트 (임시 폴더로만 꺼낸다. 설치된 사본은 위 줄이 {app} 에 둔다)
Source: "{#StageDir}\stop_app.ps1"; Flags: dontcopy

[Icons]
Name: "{code:GetDesktopDir}\회화 연습"; Filename: "{app}\회화연습.exe"; WorkingDir: "{app}"; Check: ShortcutsEnabled
Name: "{code:GetStartMenuDir}\회화 연습"; Filename: "{app}\회화연습.exe"; WorkingDir: "{app}"; Check: ShortcutsEnabled
Name: "{code:GetStartMenuDir}\회화 연습 업데이트"; Filename: "{app}\업데이트.bat"; WorkingDir: "{app}"; Check: ShortcutsEnabled
Name: "{code:GetStartMenuDir}\회화 연습 제거"; Filename: "{uninstallexe}"; Check: ShortcutsEnabled

[UninstallDelete]
; 설치 뒤에 생기는 것들 (Inno 는 자기가 푼 파일만 지운다). 폴더 전체({app})를 지우지 않고 아는 것만 지운다:
; /DIR 로 이미 다른 파일이 있는 폴더를 골랐어도 그 파일은 건드리지 않는다. 비면 Inno 가 폴더 자체를 지운다.
; 학습 기록(%APPDATA%\Godot\app_userdata\회화 연습)과 OpenCode 로그인은 여기에 없다 = 절대 지우지 않는다.
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\backend"
Type: filesandordirs; Name: "{app}\vendor"
Type: filesandordirs; Name: "{app}\defaults"
Type: filesandordirs; Name: "{app}\backup"
Type: filesandordirs; Name: "{app}\__pycache__"
Type: files; Name: "{app}\install.log"
Type: files; Name: "{app}\update.log"
Type: files; Name: "{app}\version.txt"
Type: files; Name: "{app}\manifest.json"

[Code]
const
  PROGRESS_TICK_MS = 400;
  WAIT_TIMEOUT = 258;
  BM_CLICK = $00F5;
  CREATE_NO_WINDOW = $08000000;

type
  TStartupInfo = record
    cb: DWORD;
    lpReserved: Longint;
    lpDesktop: Longint;
    lpTitle: Longint;
    dwX: DWORD;
    dwY: DWORD;
    dwXSize: DWORD;
    dwYSize: DWORD;
    dwXCountChars: DWORD;
    dwYCountChars: DWORD;
    dwFillAttribute: DWORD;
    dwFlags: DWORD;
    wShowWindow: Word;
    cbReserved2: Word;
    lpReserved2: Longint;
    hStdInput: THandle;
    hStdOutput: THandle;
    hStdError: THandle;
  end;
  TMsg = record
    hwnd: Longint;
    message: Cardinal;
    wParam: Longint;
    lParam: Longint;
    time: DWORD;
    ptX: Longint;
    ptY: Longint;
  end;
  TProcessInformation = record
    hProcess: THandle;
    hThread: THandle;
    dwProcessId: DWORD;
    dwThreadId: DWORD;
  end;

var
  ProgFile: String;
  ProgBase, ProgSpan: Integer;     // 진행 막대: Base .. Base+Span 을 install.ps1 의 pct(0~100)에 대응시킨다
  ShownPct: Integer;               // 막대는 줄어들지 않는다
  LastState, LastTitle, LastDetail, LastError, LastWarn, LastLog: String;
  LastStep, LastSteps, LastCode: Integer;
  GotProgress: Boolean;
  LastPctValue: Integer;
  InstallOk: Boolean;
  LastExit: Integer;
  FailExitCode: Integer;           // 0 = 성공. 0 이 아니면 setup.exe 가 이 코드로 끝난다 (install.ps1 의 종료 코드 그대로: 10 점검 20 인터넷 30 해시 40 패키지 50 모델 60 동작 확인 1 그 밖)
  FailText: String;

function CreateProcessW(lpApplicationName: String; lpCommandLine: String; lpProcessAttributes: Longint; lpThreadAttributes: Longint; bInheritHandles: BOOL; dwCreationFlags: DWORD; lpEnvironment: Longint; lpCurrentDirectory: String; var lpStartupInfo: TStartupInfo; var lpProcessInformation: TProcessInformation): BOOL;
  external 'CreateProcessW@kernel32.dll stdcall';
function PeekMessageW(var lpMsg: TMsg; hWnd: Longint; wMsgFilterMin: Cardinal; wMsgFilterMax: Cardinal; wRemoveMsg: Cardinal): BOOL;
  external 'PeekMessageW@user32.dll stdcall';
function TranslateMessage(var lpMsg: TMsg): BOOL;
  external 'TranslateMessage@user32.dll stdcall';
function DispatchMessageW(var lpMsg: TMsg): Longint;
  external 'DispatchMessageW@user32.dll stdcall';
function PostMessageW(hWnd: HWND; Msg: Cardinal; wParam: Longint; lParam: Longint): BOOL;
  external 'PostMessageW@user32.dll stdcall';
function WaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function GetExitCodeProcess(hProcess: THandle; var lpExitCode: DWORD): BOOL;
  external 'GetExitCodeProcess@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';
procedure ExitProcess(uExitCode: Cardinal);
  external 'ExitProcess@kernel32.dll stdcall';
function MultiByteToWideChar(CodePage: Cardinal; dwFlags: Cardinal; lpMultiByteStr: AnsiString; cbMultiByte: Integer; lpWideCharStr: String; cchWideChar: Integer): Integer;
  external 'MultiByteToWideChar@kernel32.dll stdcall';

// ------------------------------------------------------------------ 기본 설치 폴더
// 규칙: <LOCALAPPDATA>\Programs\회화연습. 그 경로가 80자를 넘으면 (긴 한글 사용자 이름 등) 짧은 폴더를 쓴다 (파이썬 패키지는 경로가 길면 깨진다).
function ChooseDefaultDir(const LocalAppData, Fallback: String): String;
var
  Candidate: String;
begin
  Candidate := LocalAppData + '\Programs\회화연습';
  if Length(Candidate) > 80 then
    Result := Fallback
  else
    Result := Candidate;
end;

function BaseLocalAppData: String;
begin
  Result := ExpandConstant('{localappdata}');
#if IsTest
  if GetEnv('HOEHWA_TEST_LOCALAPPDATA') <> '' then
    Result := GetEnv('HOEHWA_TEST_LOCALAPPDATA');
#endif
end;

function FallbackDir: String;
begin
  Result := 'C:\회화연습';
#if IsTest
  if GetEnv('HOEHWA_TEST_FALLBACK_DIR') <> '' then
    Result := GetEnv('HOEHWA_TEST_FALLBACK_DIR');
#endif
end;

function GetDefaultDir(Param: String): String;
begin
  Result := ChooseDefaultDir(BaseLocalAppData, FallbackDir);
end;

// ------------------------------------------------------------------ 바로가기 경로 (시험용은 환경변수로 돌린다)
function ShortcutsEnabled: Boolean;
begin
#if IsTest
  Result := GetEnv('HOEHWA_TEST_SHORTCUT_DIR') <> '';
#else
  Result := True;
#endif
end;

function GetDesktopDir(Param: String): String;
begin
#if IsTest
  Result := GetEnv('HOEHWA_TEST_SHORTCUT_DIR') + '\Desktop';
#else
  Result := ExpandConstant('{autodesktop}');
#endif
end;

function GetStartMenuDir(Param: String): String;
begin
#if IsTest
  Result := GetEnv('HOEHWA_TEST_SHORTCUT_DIR') + '\Programs\회화 연습';
#else
  Result := ExpandConstant('{autoprograms}') + '\회화 연습';
#endif
end;

// 기다리는 동안 창이 '응답 없음'이 되지 않도록 화면 메시지를 처리한다
procedure PumpMessages;
var
  Msg: TMsg;
begin
  while PeekMessageW(Msg, 0, 0, 0, 1) do
  begin
    TranslateMessage(Msg);
    DispatchMessageW(Msg);
  end;
end;

// ------------------------------------------------------------------ 진행 파일 읽기
function Utf8ToStr(const A: AnsiString): String;
var
  N: Integer;
begin
  Result := '';
  if Length(A) = 0 then Exit;
  N := MultiByteToWideChar(65001, 0, A, Length(A), '', 0);
  if N <= 0 then Exit;
  SetLength(Result, N);
  MultiByteToWideChar(65001, 0, A, Length(A), Result, N);
end;

// JSON 한 줄에서 "key": 뒤의 문자열 값을 꺼낸다 (\" \\ \uXXXX 처리). 없으면 ''
function JsonStr(const J, Key: String): String;
var
  P, U: Integer;
  C: Char;
  Needle: String;
begin
  Result := '';
  Needle := '"' + Key + '":';
  P := Pos(Needle, J);
  if P = 0 then Exit;
  P := P + Length(Needle);
  while (P <= Length(J)) and (J[P] = ' ') do P := P + 1;
  if (P > Length(J)) or (J[P] <> '"') then Exit;
  P := P + 1;
  while P <= Length(J) do
  begin
    C := J[P];
    if C = '"' then Break;
    if C = '\' then
    begin
      P := P + 1;
      if P > Length(J) then Break;
      C := J[P];
      if (C = 'n') or (C = 'r') or (C = 't') then
        Result := Result + ' '
      else if C = 'u' then
      begin
        U := StrToIntDef('$' + Copy(J, P + 1, 4), 63);
        Result := Result + Chr(U);
        P := P + 4;
      end
      else
        Result := Result + C;
    end
    else
      Result := Result + C;
    P := P + 1;
  end;
end;

function JsonInt(const J, Key: String; Default: Integer): Integer;
var
  P: Integer;
  Needle, Digits: String;
begin
  Result := Default;
  Needle := '"' + Key + '":';
  P := Pos(Needle, J);
  if P = 0 then Exit;
  P := P + Length(Needle);
  Digits := '';
  while (P <= Length(J)) and (J[P] >= '0') and (J[P] <= '9') do
  begin
    Digits := Digits + J[P];
    P := P + 1;
  end;
  if Digits <> '' then Result := StrToIntDef(Digits, Default);
end;

function StepText: String;
begin
  Result := LastTitle;
  if (LastStep > 0) and (LastSteps > 0) and (LastState = 'running') then
    Result := Result + ' (' + IntToStr(LastStep) + '/' + IntToStr(LastSteps) + ')';
end;

// 진행 파일을 열자마자 읽고 닫는다. 쓰는 쪽이 파일을 바꾸는 중이라 못 읽으면 (파일 없음, 잠김) 이번 틱은 건너뛰고 다음에 다시 읽는다.
function ReadProgressFile: Boolean;
var
  Raw: AnsiString;
  J: String;
  Pct: Integer;
begin
  Result := False;
  if ProgFile = '' then Exit;
  if not FileExists(ProgFile) then Exit;
  Raw := '';
  if not LoadStringFromFile(ProgFile, Raw) then Exit;
  if Length(Raw) < 2 then Exit;
  J := Utf8ToStr(Raw);
  if (Pos('"state":', J) = 0) or (Pos('"pct":', J) = 0) then Exit;   // 반쯤 쓴 파일이면 건너뜀
  LastState := JsonStr(J, 'state');
  LastTitle := JsonStr(J, 'title');
  LastDetail := JsonStr(J, 'detail');
  LastError := JsonStr(J, 'error');
  LastWarn := JsonStr(J, 'warn');
  LastLog := JsonStr(J, 'log');
  LastStep := JsonInt(J, 'step', 0);
  LastSteps := JsonInt(J, 'steps', 0);
  LastCode := JsonInt(J, 'code', 0);
  Pct := JsonInt(J, 'pct', 0);
  if Pct > 100 then Pct := 100;
  if Pct > LastPctValue then LastPctValue := Pct;
  GotProgress := True;
  Result := True;
end;

procedure UpdateProgressUi;
var
  Target: Integer;
begin
  if not GotProgress then Exit;
  Target := ProgBase + (ProgSpan div 100) * LastPctValue;
  if Target > ShownPct then
  begin
    ShownPct := Target;
    WizardForm.ProgressGauge.Position := ShownPct;
  end;
  if LastTitle <> '' then WizardForm.StatusLabel.Caption := StepText;
  WizardForm.FilenameLabel.Caption := LastDetail;
end;

// ------------------------------------------------------------------ 실행 중인 프로세스 정리 (설치 폴더 아래 것만, PID 로)
function PowerShellExe: String;
begin
  Result := ExpandConstant('{sys}') + '\WindowsPowerShell\v1.0\powershell.exe';
end;

procedure StopRunningApp(const ScriptPath, Root: String);
var
  Rc: Integer;
  Report: String;
  Lines: TArrayOfString;
  I: Integer;
begin
  if not FileExists(ScriptPath) then Exit;
  Report := ExpandConstant('{tmp}') + '\hoehwa-stop-report.txt';
  DeleteFile(Report);
  if Exec(PowerShellExe, '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '" -Root "' + Root + '" -ReportFile "' + Report + '"',
          '', SW_HIDE, ewWaitUntilTerminated, Rc) then
  begin
    Log('stop_app.ps1 exit ' + IntToStr(Rc));
    if LoadStringsFromFile(Report, Lines) then
      for I := 0 to GetArrayLength(Lines) - 1 do
        if Trim(Lines[I]) <> '' then Log('stop_app: ' + Lines[I]);
  end
  else
    Log('stop_app.ps1 을 시작하지 못했어요: ' + SysErrorMessage(DLLGetLastError));
end;

// ------------------------------------------------------------------ install.ps1 실행
// 성공하면 True. 실패하면 FailText 에 한국어 이유가 들어 있다.
function RunInstallScript: Boolean;
var
  Ps1, Params, LogHint, CmdLine: String;
  Rc: Integer;
  Started: Boolean;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Wr, ExitCode: DWORD;
begin
  Result := False;
  FailText := '';
  Ps1 := ExpandConstant('{app}') + '\install.ps1';
  if not FileExists(Ps1) then
  begin
    FailText := '설치 파일이 빠져 있어요 (install.ps1). 설치 프로그램을 다시 받아 실행해 주세요.';
    Exit;
  end;
  ProgFile := ExpandConstant('{tmp}') + '\hoehwa-setup-progress.json';
  DeleteFile(ProgFile);
  LastState := ''; LastTitle := ''; LastDetail := ''; LastError := ''; LastWarn := ''; LastLog := '';
  LastStep := 0; LastSteps := 0; LastCode := 0; LastPctValue := 0; GotProgress := False;

  WizardForm.CancelButton.Enabled := False;     // 파일은 이미 풀렸다: 도중에 취소로 되돌리지 않는다 (다시 실행하면 이어서 한다)
  WizardForm.StatusLabel.Caption := '설치를 시작하는 중';
  WizardForm.FilenameLabel.Caption := '';

  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Ps1 + '" -ProgressFile "' + ProgFile + '"';
  Log('install.ps1 시작: ' + Params);
  // 프로세스를 직접 만들어 기다린다: 기다리는 동안 0.4초마다 진행 파일을 읽어 막대를 움직이고 화면 메시지를 처리한다
  CmdLine := '"' + PowerShellExe + '" ' + Params;
  SI.cb := SizeOf(SI);
  SI.lpReserved := 0; SI.lpDesktop := 0; SI.lpTitle := 0;
  SI.dwX := 0; SI.dwY := 0; SI.dwXSize := 0; SI.dwYSize := 0; SI.dwXCountChars := 0; SI.dwYCountChars := 0; SI.dwFillAttribute := 0;
  SI.dwFlags := 0; SI.wShowWindow := 0; SI.cbReserved2 := 0; SI.lpReserved2 := 0; SI.hStdInput := 0; SI.hStdOutput := 0; SI.hStdError := 0;
  PI.hProcess := 0; PI.hThread := 0; PI.dwProcessId := 0; PI.dwThreadId := 0;
  Started := CreateProcessW(PowerShellExe, CmdLine, 0, 0, False, CREATE_NO_WINDOW, 0, ExpandConstant('{app}'), SI, PI);
  Rc := -1;
  LastExit := -1;
  if Started then
  begin
    repeat
      Wr := WaitForSingleObject(PI.hProcess, PROGRESS_TICK_MS);
      if ReadProgressFile then UpdateProgressUi;
      PumpMessages;
    until Wr <> WAIT_TIMEOUT;
    ExitCode := 0;
    if GetExitCodeProcess(PI.hProcess, ExitCode) then Rc := ExitCode;
    LastExit := Rc;
    CloseHandle(PI.hProcess);
    CloseHandle(PI.hThread);
  end;

  // 마지막 상태를 한 번 더 읽는다 (타이머가 못 읽은 마지막 쓰기)
  if ReadProgressFile then UpdateProgressUi;
  Log('install.ps1 끝: 시작=' + IntToStr(Ord(Started)) + ' 종료코드=' + IntToStr(Rc) + ' 상태=' + LastState + ' 단계=' + IntToStr(LastStep) + ' 진행=' + IntToStr(LastPctValue) + ' 코드=' + IntToStr(LastCode));
  if LastWarn <> '' then Log('install.ps1 경고: ' + LastWarn);

  LogHint := LastLog;
  if LogHint = '' then LogHint := ExpandConstant('{app}') + '\install.log';
  if not Started then
  begin
    FailText := 'PowerShell 을 실행하지 못했어요 (' + SysErrorMessage(DLLGetLastError) + ').' + #13#10#13#10 + '기록 파일: ' + LogHint;
    Exit;
  end;
  if (Rc = 0) and (LastState = 'done') then
  begin
    Result := True;
    Exit;
  end;
  if LastState = 'error' then
    FailText := LastError
  else if Rc <> 0 then
    FailText := '설치 스크립트가 예기치 않게 끝났어요 (코드 ' + IntToStr(Rc) + ').'
  else
    FailText := '설치가 끝까지 진행되지 않았어요.';
  if FailText = '' then FailText := '설치를 끝내지 못했어요 (코드 ' + IntToStr(Rc) + ').';
  FailText := FailText + #13#10#13#10 + '기록 파일: ' + LogHint + #13#10 + '설치 파일을 다시 실행하면 끝난 단계는 건너뛰고 이어서 해요.';
end;

// ------------------------------------------------------------------ 설치 흐름
function InitializeSetup: Boolean;
var
  Base: String;
begin
  Result := True;
#if IsTest
  Base := ExpandConstant('{param:PATHRULE|}');
  if Base <> '' then
  begin
    Log('PATHRULE base=' + Base + ' choice=' + ChooseDefaultDir(Base, FallbackDir) + ' len=' + IntToStr(Length(Base + '\Programs\회화연습')));
    Result := False;
  end;
#endif
end;

// 질문 페이지는 Disable*Page 로 모두 끈다. 그런데 '설치 준비 완료 - 설치(I)' 페이지는 꺼도 한 번 뜨고 사용자의 클릭을 기다린다(실측: 보이는 모드에서 멈춤).
// 그래서 이 페이지가 뜨면 다음 단추를 코드로 눌러 바로 넘어간다. 사용자가 누를 것은 없다.
procedure CurPageChanged(CurPageID: Integer);
begin
  Log('페이지 표시: ' + IntToStr(CurPageID));
  if CurPageID = wpReady then
  begin
    Log('준비 완료 페이지가 떠서 자동으로 넘어갑니다 (다음 단추 켜짐=' + IntToStr(Ord(WizardForm.NextButton.Enabled)) + ' 보임=' + IntToStr(Ord(WizardForm.NextButton.Visible)) + ')');
    PostMessageW(WizardForm.NextButton.Handle, BM_CLICK, 0, 0);
  end;
end;

procedure DeinitializeSetup;
begin
  if FailExitCode <> 0 then
  begin
    Log('setup.exe 를 실패 코드 ' + IntToStr(FailExitCode) + ' 로 끝냅니다 (설치된 파일은 그대로 둠).');
    ExitProcess(FailExitCode);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Tmp: String;
  LaunchRc: Integer;
begin
  if CurStep = ssInstall then
  begin
    // 다시 설치/업데이트 때 파일이 잠기지 않게: 설치 폴더 아래에서 실행 중인 프로세스만 끈다
    WizardForm.StatusLabel.Caption := '실행 중인 프로그램을 정리하는 중';
    try
      ExtractTemporaryFile('stop_app.ps1');
      Tmp := ExpandConstant('{tmp}') + '\stop_app.ps1';
      StopRunningApp(Tmp, ExpandConstant('{app}'));
    except
      Log('프로세스 정리 단계에서 예외: ' + GetExceptionMessage);
    end;
    Log('진행 막대(파일 풀기 전): 최소=' + IntToStr(WizardForm.ProgressGauge.Min) + ' 최대=' + IntToStr(WizardForm.ProgressGauge.Max) + ' 위치=' + IntToStr(WizardForm.ProgressGauge.Position));
  end;
  if CurStep = ssPostInstall then
  begin
    Log('진행 막대(파일 푼 뒤): 최소=' + IntToStr(WizardForm.ProgressGauge.Min) + ' 최대=' + IntToStr(WizardForm.ProgressGauge.Max) + ' 위치=' + IntToStr(WizardForm.ProgressGauge.Position));
    // 파일 풀기가 막대의 첫 12분의 1을 쓴 것으로 하고, 나머지로 install.ps1 의 진행(0~100)을 보여 준다 (막대가 줄어들지 않는다)
    ProgBase := WizardForm.ProgressGauge.Position;
    if ProgBase < 1 then ProgBase := 1;
    WizardForm.ProgressGauge.Max := ProgBase * 12;
    ProgSpan := WizardForm.ProgressGauge.Max - ProgBase;
    ShownPct := ProgBase;
    InstallOk := RunInstallScript;
    if not InstallOk then
    begin
      Log('설치 실패: ' + FailText);
      SuppressibleMsgBox('회화 연습 설치를 끝내지 못했어요.' + #13#10#13#10 + FailText, mbCriticalError, MB_OK, IDOK);
      // 예외를 던지지 않는다 (던지면 Setup 이 '성공'으로 끝나면서 불필요한 오류 창이 한 번 더 뜬다). 파일은 그대로 두고 (다시 실행하면 이어서 한다),
      // 끝낼 때 DeinitializeSetup 이 실패 코드로 끝낸다.
      if LastCode > 0 then FailExitCode := LastCode
      else if LastExit > 0 then FailExitCode := LastExit
      else FailExitCode := 1;
      Exit;
    end;
    // 5·6단계(OpenCode, 자바)처럼 설치를 막지 않는 실패는 끝에 한 번 알린다
    if LastWarn <> '' then
      SuppressibleMsgBox('설치는 끝났어요. 참고해 주세요.' + #13#10#13#10 + LastWarn, mbInformation, MB_OK, IDOK);
#if IsTest == 0
    // 끝나면 앱을 연다 (조용한 설치에서는 열지 않는다)
    if not WizardSilent then
      Exec(ExpandConstant('{app}') + '\회화연습.exe', '', ExpandConstant('{app}'), SW_SHOWNORMAL, ewNoWait, LaunchRc);
#endif
  end;
end;

// ------------------------------------------------------------------ 제거
function OpenCodeWorkDir: String;
begin
  Result := '';
#if IsTest
  if GetEnv('HOEHWA_TEST_LOCALAPPDATA') <> '' then
    Result := GetEnv('HOEHWA_TEST_LOCALAPPDATA') + '\hoehwa-practice\opencode';
#else
  Result := ExpandConstant('{localappdata}') + '\hoehwa-practice\opencode';
#endif
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Dir: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    // 실행 중인 앱·서버를 PID 로 끈다 (이 폴더 아래 것만)
    StopRunningApp(ExpandConstant('{app}') + '\stop_app.ps1', ExpandConstant('{app}'));
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    // OpenCode 작업 폴더(opencode serve 가 쓰던 임시 작업 공간)는 지운다. 이름 끝이 정확히 맞을 때만.
    Dir := OpenCodeWorkDir;
    if (Dir <> '') and (Pos('\hoehwa-practice\opencode', LowerCase(Dir)) = Length(Dir) - Length('\hoehwa-practice\opencode') + 1) then
    begin
      if DirExists(Dir) then DelTree(Dir, True, True, True);
    end;
  end;
  if CurUninstallStep = usDone then
  begin
    SuppressibleMsgBox('회화 연습을 제거했어요.' + #13#10#13#10 + '학습 기록은 지우지 않고 남겨 두었어요:' + #13#10 + ExpandConstant('{userappdata}') + '\Godot\app_userdata\회화 연습', mbInformation, MB_OK, IDOK);
  end;
end;
