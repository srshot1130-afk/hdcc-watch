# 해운대CC 예약 1회 확인 (GitHub Actions 에서 5분마다 실행)
# 필요한 값은 GitHub 저장소 Settings 의 Secrets/Variables 에서 받음:
#   HDCC_ID, HDCC_PW, NTFY_TOPIC (Secrets) / TARGET_DATE, HDCC_LOGIN_TYPE (Variables)

$ErrorActionPreference = 'Stop'
$Base       = 'https://www.haeundaecc.co.kr'
$ResvUrl    = "$Base/Reservation/Reservation.aspx"
$UA         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$TargetDate = $env:TARGET_DATE
$LoginType  = if ($null -ne $env:HDCC_LOGIN_TYPE) { $env:HDCC_LOGIN_TYPE } else { '0' }   # 0=정회원, 1=준회원, 빈값=사이버회원
$Topic      = $env:NTFY_TOPIC
$NowKst     = [DateTime]::UtcNow.AddHours(9)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Send-Ntfy($title, $text, $priority = 5, $tag = 'golf') {
    $json = @{ topic = $Topic; title = $title; message = $text; priority = $priority
               tags = @($tag); click = $ResvUrl } | ConvertTo-Json -Compress
    $null = Invoke-RestMethod 'https://ntfy.sh' -Method Post -UseBasicParsing `
                -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

function Test-RecentlySent($title, $since) {
    # 서버는 매번 새로 시작해서 기억이 없음 → ntfy 채널의 최근 메시지로 중복 알림 방지
    $r = Invoke-WebRequest "https://ntfy.sh/$Topic/json?poll=1&since=$since" -UseBasicParsing
    $body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    foreach ($line in $body -split "`n") {
        if (-not $line.Trim()) { continue }
        $m = $line | ConvertFrom-Json
        if ($m.event -eq 'message' -and $m.title -eq $title -and $m.message -like "*$TargetDate*") { return $true }
    }
    $false
}

function Get-Html($resp) { [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) }

function Get-HiddenFields($html) {
    $fields = @{}
    foreach ($m in [regex]::Matches($html, '<input[^>]*type="hidden"[^>]*>')) {
        $n = [regex]::Match($m.Value, 'name="([^"]*)"').Groups[1].Value
        $v = [regex]::Match($m.Value, 'value="([^"]*)"').Groups[1].Value
        if ($n) { $fields[$n] = [Net.WebUtility]::HtmlDecode($v) }
    }
    $fields
}

function Get-DateStatus($html, $target) {
    $open = [regex]::Match($html, "<td class=""team[^""]*"">\s*<a href=""javascript:Update\('LIST\|[^|]*\|$TargetDate\|[^']*'\);"">\s*\d+\s*<span>([^<]*)</span>")
    if ($open.Success) { return [pscustomobject]@{ Open = $true; Text = $open.Groups[1].Value.Trim() } }
    $hdr = [regex]::Match($html, ('{0}\.\s*</span>\s*<span class="month">{1:MM}</span>' -f $target.Year, $target))
    if (-not $hdr.Success) { throw '달력을 찾지 못함 (사이트 구조 변경 또는 로그인 실패)' }
    $cell = [regex]::Match($html.Substring($hdr.Index), "<td class=""[^""]*"">\s*<a [^>]*>\s*$($target.Day)\s*<span>([^<]*)</span>")
    if (-not $cell.Success) { throw '날짜 칸을 찾지 못함' }
    [pscustomobject]@{ Open = $false; Text = $cell.Groups[1].Value.Trim() }
}

try {
    if (-not $env:HDCC_ID -or -not $env:HDCC_PW -or -not $Topic -or -not $TargetDate) {
        throw 'Secrets/Variables 설정 누락 (HDCC_ID, HDCC_PW, NTFY_TOPIC, TARGET_DATE)'
    }
    $target = [datetime]::ParseExact($TargetDate, 'yyyy-MM-dd', $null)
    $label  = '{0:yyyy-MM-dd}({1})' -f $target, '일월화수목금토'[[int]$target.DayOfWeek]
    if ($target -lt $NowKst.Date) { Write-Host "$label 은 이미 지난 날짜입니다. TARGET_DATE 를 바꾸거나 워크플로를 끄세요."; exit 0 }

    # 로그인
    $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $r = Invoke-WebRequest "$Base/Member/Login.aspx" -WebSession $s -UserAgent $UA -UseBasicParsing
    $body = Get-HiddenFields (Get-Html $r)
    $body['__EVENTTARGET']                              = 'ctl00$ContentPlaceHolder1$ibtnLogin'
    $body['__EVENTARGUMENT']                            = ''
    $body['ctl00$ContentPlaceHolder1$rblLoginTypeList'] = $LoginType
    $body['ctl00$ContentPlaceHolder1$txtUserID']        = $env:HDCC_ID
    $body['ctl00$ContentPlaceHolder1$txtPassword']      = $env:HDCC_PW
    $null = Invoke-WebRequest "$Base/Member/Login.aspx" -Method Post -Body $body -WebSession $s `
                -UserAgent $UA -UseBasicParsing -Headers @{ Referer = "$Base/Member/Login.aspx" }
    if (-not ($s.Cookies.GetCookies($Base) | Where-Object { $_.Name -eq 'MemberID' -and $_.Value })) {
        throw '로그인 실패 (아이디/비밀번호 또는 회원구분 확인)'
    }
    Write-Host '로그인 성공'

    # 대상 월 달력
    $r = Invoke-WebRequest $ResvUrl -WebSession $s -UserAgent $UA -UseBasicParsing
    $body = Get-HiddenFields (Get-Html $r)
    $body['__EVENTTARGET']                     = 'ctl00$ContentPlaceHolder1$btnUp'
    $body['__EVENTARGUMENT']                   = ''
    $body['ctl00$ContentPlaceHolder1$htbArgs'] = 'CALENDAR|{0:yyyy-MM}-01|{1:yyyy-MM-dd}' -f $target, $NowKst
    $r = Invoke-WebRequest $ResvUrl -Method Post -Body $body -WebSession $s -UserAgent $UA -UseBasicParsing -Headers @{ Referer = $ResvUrl }

    $st = Get-DateStatus (Get-Html $r) $target
    Write-Host ("$label 상태: " + $(if ($st.Open) { "예약 가능 ($($st.Text))" } else { $st.Text }))

    if ($st.Open) {
        # 열려 있는 동안 30분마다 다시 알려줌
        if (-not (Test-RecentlySent '해운대CC 예약 가능!' '30m')) {
            Send-Ntfy '해운대CC 예약 가능!' "$label 예약 가능 ($($st.Text)) - 눌러서 바로 예약하세요."
            Write-Host 'ntfy 알림 전송'
        }
    }
}
catch {
    $msg = $_.Exception.Message
    Write-Host "오류: $msg"
    # 오류 알림은 2시간에 한 번만
    try {
        if ($Topic -and -not (Test-RecentlySent '해운대CC 감시 멈춤!' '2h')) {
            Send-Ntfy '해운대CC 감시 멈춤!' "[GitHub] $TargetDate 확인 실패: $msg" 4 'warning'
        }
    } catch {}
    exit 1
}
