# update.ps1 의 릴리스 선택 규칙 시험 (v2.0.2 FXB): 비안정 채널은 v 와 숫자로 시작하는 앱 태그만 고르고(models-1 같은 태그는 건너뜀),
# 안정 채널은 앱 태그가 아니면 업데이트 대신 안내와 함께 멈춘다.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test_update_channel.ps1 [-UpdatePs1 <update.ps1 경로>]
# 마지막 줄: UPDATE_CHANNEL_TEST_OK cases=N (종료 0) 또는 UPDATE_CHANNEL_TEST_FAIL failed=K cases=N (종료 1).
# 방법: update.ps1 을 Parser 로 읽어 Parse-Ver / Test-AppTag / Test-TagVersion / Select-UpdateRelease / Get-LatestRelease 다섯 함수 정의만 꺼내 이 시험 안에 정의한다
# (update.ps1 본문은 실행하지 않는다). Get-LatestRelease 는 Invoke-WebRequest 를 가짜 함수로 바꿔서 부른다: 실제 GitHub 접속·파일 쓰기 없음.
param([string]$UpdatePs1 = "")
$ErrorActionPreference = "Stop"
if (-not $UpdatePs1) { $UpdatePs1 = Join-Path $PSScriptRoot "installer\update.ps1" }
$script:cases = 0
$script:failed = 0
$script:quiet = $false

function Check([string]$name, [bool]$ok) {
    $script:cases++
    if (-not $ok) { $script:failed++; if (-not $script:quiet) { Write-Output ("FAIL {0}" -f $name) } }
}

function Rel([string]$tag, [bool]$draft = $false) { [pscustomobject]@{ tag_name = $tag; draft = $draft } }

# 같은 시험 표를 어떤 구현에도 돌릴 수 있게: 이름 -> 고른 태그("" = $null) 를 돌려준다
function Tag-Of($r) { if ($null -eq $r) { "" } else { "" + $r.tag_name } }

function Run-SelectCases([scriptblock]$select, [scriptblock]$isApp, [string]$prefix) {
    $tbl = @(
        @{ n = "models-1 이 앞이면 건너뜀";         list = @((Rel "models-1"), (Rel "v2.0.2"));                              want = "v2.0.2" },
        @{ n = "draft v2.0.3 과 models-1 을 건너뜀"; list = @((Rel "v2.0.3" $true), (Rel "models-1"), (Rel "v2.0.2"));        want = "v2.0.2" },
        @{ n = "models-1 하나뿐이면 없음";           list = @((Rel "models-1"));                                              want = "" },
        @{ n = "빈 목록이면 없음";                   list = @();                                                              want = "" },
        @{ n = "null 칸은 건너뜀";                   list = @($null, (Rel "v2.0.1"));                                         want = "v2.0.1" },
        @{ n = "v2.0.2-rc1 도 앱 태그";              list = @((Rel "models-1"), (Rel "v2.0.2-rc1"), (Rel "v2.0.1"));          want = "v2.0.2-rc1" },
        @{ n = "v 없는 2.0.1 은 앱 태그가 아님";     list = @((Rel "2.0.1"), (Rel "models-1"));                               want = "" },
        @{ n = "2.0.1 다음의 v2.0.1 을 고름";        list = @((Rel "2.0.1"), (Rel "v2.0.1"));                                 want = "v2.0.1" },
        @{ n = "대문자 V2.0.1 은 앱 태그";           list = @((Rel "models-1"), (Rel "2.0.1"), (Rel "V2.0.1"));               want = "V2.0.1" },
        @{ n = "draft 만 있으면 없음";               list = @((Rel "v2.0.9" $true));                                          want = "" },
        @{ n = "앞의 앱 태그를 먼저 고름";           list = @((Rel "v2.0.2"), (Rel "v2.0.1"), (Rel "models-1"));              want = "v2.0.2" },
        @{ n = "v2docs 가 v2.0.2 를 가리지 않음";    list = @((Rel "v2docs"), (Rel "v2.0.2"));                                want = "v2.0.2" },
        @{ n = "아라비아 숫자 v١ 를 건너뜀";         list = @((Rel ("v" + [char]0x0661)), (Rel "v2.0.2"));                    want = "v2.0.2" },
        @{ n = "범위 밖 v2147483648 을 건너뜀";      list = @((Rel "v2147483648"), (Rel "v2.0.2"));                           want = "v2.0.2" },
        @{ n = "범위 밖 v2147483648.0 을 건너뜀";    list = @((Rel "v2147483648.0"), (Rel "v2.0.2"));                         want = "v2.0.2" },
        @{ n = "v2docs·v١·v2147483648 뒤의 v2.0.2";  list = @((Rel "v2docs"), (Rel ("v" + [char]0x0661)), (Rel "v2147483648"), (Rel "v2.0.2")); want = "v2.0.2" },
        @{ n = "정상 후보가 없으면 없음(전부 비정상)"; list = @((Rel "v2docs"), (Rel "v2147483648"), (Rel "models-1"));       want = "" },
        @{ n = "v2.0.2-rc1.5 처럼 - 뒤 점도 허용";   list = @((Rel "v2.0.2-rc1.5"));                                          want = "v2.0.2-rc1.5" },
        @{ n = "점 없는 v2 는 앱 태그가 아님";       list = @((Rel "v2"), (Rel "v2.0.2"));                                    want = "v2.0.2" }
    )
    foreach ($c in $tbl) {
        $got = Tag-Of (& $select $c.list)
        Check ("{0}select: {1} (got '{2}')" -f $prefix, $c.n, $got) ($got -eq $c.want)
    }
    $tags = @(
        @{ t = "v2.0.1"; want = $true }, @{ t = "V2.0.1"; want = $true }, @{ t = "v2.0.2-rc1"; want = $true }, @{ t = "v1.9"; want = $true }, @{ t = "v2.0.1.4"; want = $true }, @{ t = "v2.0.1-rc.1"; want = $true },
        @{ t = "v1"; want = $false }, @{ t = "v2docs"; want = $false }, @{ t = "v2.0docs"; want = $false }, @{ t = "v2.0.1.2.3"; want = $false },
        @{ t = "v2.0.1-"; want = $false }, @{ t = "v2.0.1-rc 1"; want = $false }, @{ t = "v2.0.1`n"; want = $false },
        @{ t = ("v" + [char]0x0661); want = $false }, @{ t = ("v2." + [char]0x0662); want = $false }, @{ t = "v2..1"; want = $false },
        @{ t = "2.0.1"; want = $false }, @{ t = "models-1"; want = $false }, @{ t = "v"; want = $false }, @{ t = "release-2"; want = $false },
        @{ t = ""; want = $false }, @{ t = " v2"; want = $false }, @{ t = "vx1"; want = $false }
    )
    foreach ($c in $tags) {
        Check ("{0}tag: '{1}'" -f $prefix, $c.t) ([bool](& $isApp $c.t) -eq $c.want)
    }
    Check ("{0}tag: `$null" -f $prefix) ([bool](& $isApp $null) -eq $false)
}

# ---- 1. update.ps1 에서 함수 정의만 꺼낸다
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($UpdatePs1, [ref]$tokens, [ref]$errs)
Check "update.ps1 문법 오류 0" ($errs.Count -eq 0)
$defs = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (@("Parse-Ver", "Test-AppTag", "Test-TagVersion", "Select-UpdateRelease", "Get-LatestRelease") -contains $f.Name) { $defs[$f.Name] = $f.Extent.Text }
}
foreach ($n in @("Parse-Ver", "Test-AppTag", "Test-TagVersion", "Select-UpdateRelease", "Get-LatestRelease")) { Check "함수 $n 이 update.ps1 에 있다" ($defs.ContainsKey($n)) }
if ($script:failed -gt 0) {
    "UPDATE_CHANNEL_TEST_FAIL failed=$($script:failed) cases=$($script:cases)"
    exit 1
}
foreach ($n in @("Parse-Ver", "Test-AppTag", "Test-TagVersion", "Select-UpdateRelease")) { . ([scriptblock]::Create($defs[$n])) }

# ---- 2. 두 함수: 비안정 채널 선택 표와 태그 표
Run-SelectCases { param($l) Select-UpdateRelease $l } { param($t) Test-AppTag $t } ""

# ---- 3. Get-LatestRelease 본문(문자열 검사) 과 실제 분기(가짜 Invoke-WebRequest)
$body = $defs["Get-LatestRelease"]
Check "안정 분기 안내 문구에 '앱 버전이 아니에요'" ($body.Contains("앱 버전이 아니에요"))
Check "비안정 분기가 Select-UpdateRelease 를 부른다" ($body.Contains("Select-UpdateRelease"))
Check "Select-UpdateRelease 가 버전 변환 검사(Test-TagVersion)를 쓴다" ($defs["Select-UpdateRelease"].Contains("Test-TagVersion"))
Check "Test-TagVersion 이 try 로 변환을 감싼다" ($defs["Test-TagVersion"].Contains("try") -and $defs["Test-TagVersion"].Contains("catch"))
Check "옛 Select-Object -First 1 선택이 없다" (-not $body.Contains("Select-Object -First 1"))
Check "-Source 분기가 그대로 latest.json 을 읽는다" ($body.Contains('Join-Path $Source "latest.json"'))

. ([scriptblock]::Create($defs["Get-LatestRelease"]))
function Info($m) {}
function Invoke-WebRequest {
    param($Uri, $Headers, [switch]$UseBasicParsing, $TimeoutSec)
    $script:lastUrl = "" + $Uri
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:fakeJson)
    return [pscustomobject]@{ RawContentStream = (New-Object System.IO.MemoryStream (, $bytes)) }
}
$Source = $null

function Fake-Latest([string]$json, [string]$channel) {
    $script:fakeJson = $json
    return (Get-LatestRelease "owner/repo" $channel)
}
function Fake-Throws([string]$json, [string]$channel) {
    try { [void](Fake-Latest $json $channel); return "" } catch { return "" + $_.Exception.Message }
}

# 안정 채널: 하나짜리 객체
$r = Fake-Latest '{"tag_name":"v2.0.1","draft":false}' "stable"
Check "안정: v2.0.1 을 그대로 돌려줌" ($r.tag_name -eq "v2.0.1")
Check "안정: releases/latest 주소" ($script:lastUrl -match "/releases/latest$")
$msg = Fake-Throws '{"tag_name":"models-1","draft":false}' "stable"
Check "안정: models-1 이면 안내와 함께 멈춤" ($msg.Contains("앱 버전이 아니에요") -and $msg.Contains("models-1"))
$msg = Fake-Throws '{"tag_name":"2.0.1","draft":false}' "stable"
Check "안정: v 없는 2.0.1 도 멈춤" ($msg.Contains("앱 버전이 아니에요"))
$msg = Fake-Throws '{"tag_name":"v2.0.1","draft":false}' "stable"
Check "안정: v2.0.1 은 멈추지 않음" ($msg -eq "")

# 비안정 채널: 목록
$list = '[{"tag_name":"models-1","draft":false},{"tag_name":"v2.0.2","draft":false},{"tag_name":"v2.0.1","draft":false}]'
$r = Fake-Latest $list "beta"
Check "비안정: [models-1, v2.0.2, v2.0.1] -> v2.0.2" ($r.tag_name -eq "v2.0.2")
Check "비안정: releases 목록 주소" ($script:lastUrl -match "/releases\?per_page=10$")
$r = Fake-Latest '[{"tag_name":"v2.0.3","draft":true},{"tag_name":"models-1","draft":false},{"tag_name":"v2.0.1","draft":false}]' "beta"
Check "비안정: draft v2.0.3 과 models-1 을 건너뛰고 v2.0.1" ($r.tag_name -eq "v2.0.1")
$r = Fake-Latest '[{"tag_name":"models-1","draft":false}]' "beta"
Check "비안정: models-1 하나뿐이면 null" ($null -eq $r)
$r = Fake-Latest '[{"tag_name":"2.0.1","draft":false},{"tag_name":"models-1","draft":false}]' "beta"
Check "비안정: v 없는 2.0.1 뿐이면 null" ($null -eq $r)
$r = Fake-Latest '[]' "beta"
Check "비안정: 빈 목록이면 null" ($null -eq $r)
$r = Fake-Latest '[{"tag_name":"v2.0.2-rc1","draft":false},{"tag_name":"v2.0.1","draft":false}]' "beta"
Check "비안정: v2.0.2-rc1 이 앞이면 rc1" ($r.tag_name -eq "v2.0.2-rc1")
$bad = '[{"tag_name":"v2docs","draft":false},{"tag_name":"v' + [char]0x0661 + '","draft":false},{"tag_name":"v2147483648","draft":false},{"tag_name":"v2.0.2","draft":false}]'
$r = Fake-Latest $bad "beta"
Check "비안정: v2docs·v١·v2147483648 뒤의 v2.0.2 를 고름(예외 없음)" ($r.tag_name -eq "v2.0.2")
$r = Fake-Latest '[{"tag_name":"v2147483648","draft":false}]' "beta"
Check "비안정: 변환 안 되는 태그뿐이면 예외 없이 null" ($null -eq $r)
$msg = Fake-Throws '{"tag_name":"v2147483648","draft":false}' "stable"
Check "안정: 변환 안 되는 태그도 안내와 함께 멈춤(시스템 예외 문구 아님)" ($msg.Contains("앱 버전이 아니에요"))
$msg = Fake-Throws '{"tag_name":"v2docs","draft":false}' "stable"
Check "안정: v2docs 도 멈춤" ($msg.Contains("앱 버전이 아니에요"))

# -Source(로컬 시험 원본)는 그대로: latest.json 의 내용을 걸러내지 않고 돌려준다
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("hoehwa-channel-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    [System.IO.File]::WriteAllText((Join-Path $tmp "latest.json"), '{"tag_name":"local-9","draft":false}', (New-Object System.Text.UTF8Encoding($false)))
    $Source = $tmp
    $script:lastUrl = "unset"
    $r = Get-LatestRelease "owner/repo" "stable"
    Check "-Source: latest.json 을 그대로 돌려줌(걸러내지 않음)" ($r.tag_name -eq "local-9")
    Check "-Source: 네트워크 함수를 부르지 않음" ($script:lastUrl -eq "unset")
    $r = Get-LatestRelease "owner/repo" "beta"
    Check "-Source: 비안정도 그대로" ($r.tag_name -eq "local-9")
} finally {
    $Source = $null
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 4. 시험이 틀린 구현을 실제로 잡는지(selfcheck): 옛 선택(draft 만 거르고 첫 번째)과 모든 태그를 받는 규칙
$before = $script:failed
$beforeCases = $script:cases
$script:quiet = $true
Run-SelectCases { param($l) @($l | Where-Object { $null -ne $_ -and -not $_.draft }) | Select-Object -First 1 } { param($t) $true } "bad:"
$caught = $script:failed - $before
$script:failed = $before                       # 틀린 구현의 실패는 시험 실패로 세지 않는다
$script:cases = $beforeCases
$script:quiet = $false
Check "selfcheck: 옛 선택·모든 태그 규칙을 시험이 잡는다(실패 수 >= 5)" ($caught -ge 5)
"selfcheck FAIL-as-expected old_select caught=$caught"

if ($script:failed -eq 0) {
    "UPDATE_CHANNEL_TEST_OK cases=$($script:cases)"
    exit 0
}
"UPDATE_CHANNEL_TEST_FAIL failed=$($script:failed) cases=$($script:cases)"
exit 1
