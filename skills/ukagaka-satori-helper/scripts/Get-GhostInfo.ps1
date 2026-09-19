# Get-GhostInfo.ps1
#
# SSPにSSTP経由で通信を行い、開発中のゴースト（カレントディレクトリの ghost\master\descript.txt）から
# 「任意のプロパティシステムの値」および「SHIORIリソース（またはSHIORIイベント応答）」を取得するツール。
# 
# 呼ぶ側が「プロパティかSHIORIか」を意識せずに取得できるよう、自動的に両方を試行（フォールバック）する設計となっている。
#
#   powershell -ExecutionPolicy Bypass -File Get-GhostInfo.ps1 -Name <Name>
#
# 引数
#   -Name <String> : (必須) 取得したい情報名 (プロパティ名またはSHIORIリソース/イベント名)
#
# 動作の流れ
#   1. ghost\master\descript.txt から charset を解析し、エンコーディングを自動判定してゴーストの name を読み取る。
#   2. SSP (127.0.0.1:9801) に TCP 接続を試みる。未起動なら「SSPが起動していません」として exit 1。
#   3. プロパティ `activeghostlist(GhostName).name` を確認し、対象ゴーストが起動していないなら「ゴーストが起動していません」として exit 1。
#   4. プロパティとして取得を試みる。
#      - プロパティが存在すれば (200 OK)、その戻り値を標準出力へ返して終了。
#   5. プロパティが存在しなければ、SHIORIリソース取得へ自動フォールバックする。
#      - `SEND SSTP/1.4` で `Event: <Name>` を送信し、応答（Scriptヘッダの内容）を標準出力へ返す。
#
# 実行例
#   # バルーン名を取る
#   .\Get-GhostInfo.ps1 -Name "balloon.name"

param(
    [Parameter(Mandatory)][string]$Name
)

$DescriptPath = "ghost\master\descript.txt"

if (-not (Test-Path $DescriptPath)) {
    [Console]::Error.WriteLine("${DescriptPath} が見つかりません"); exit 1
}

try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch {}

$bytes = [IO.File]::ReadAllBytes((Resolve-Path $DescriptPath).Path)
$ascii = [Text.Encoding]::ASCII.GetString($bytes)

$enc = [Text.Encoding]::GetEncoding(932)
if ($ascii -match "(?m)^[^\w]*charset\s*,\s*(.+)$" -and $Matches[1].Trim() -match "(?i)utf-8") {
    $enc = [Text.Encoding]::UTF8
}

if ($enc.GetString($bytes) -match "(?m)^[^\w]*name\s*,\s*(.+)$") {
    $GhostName = $Matches[1].Trim()
} else {
    [Console]::Error.WriteLine("${DescriptPath} から name を取得できませんでした"); exit 1
}

if ($GhostName -match "[\r\n]" -or $Name -match "[\r\n]") {
    [Console]::Error.WriteLine("引数に改行は含められません"); exit 1
}

function Send-Sstp([string]$req) {
    try {
        $t = New-Object Net.Sockets.TcpClient("127.0.0.1", 9801)
        $s = $t.GetStream(); $s.ReadTimeout = 2000
        $w = New-Object IO.StreamWriter($s, [Text.UTF8Encoding]::new($false))
        $w.Write($req); $w.Flush()
        $r = (New-Object IO.StreamReader($s, [Text.Encoding]::UTF8)).ReadToEnd()
        $t.Close(); return $r
    } catch { [Console]::Error.WriteLine("SSPが起動していません"); exit 1 }
}

$p1 = Send-Sstp "EXECUTE SSTP/1.1`r`nSender: CLI`r`nCommand: GetProperty`r`nCharset: UTF-8`r`nConnection: close`r`nReference0: activeghostlist($GhostName).name`r`n`r`n"
if ($p1 -notmatch "^SSTP/1.\d 200") { [Console]::Error.WriteLine("ゴースト（${GhostName}）は起動していません"); exit 1 }

$prop = if ($Name -match "^(activeghostlist|currentghost|system\.|ghostpath)") { $Name } else { "activeghostlist($GhostName).$Name" }
$p2 = Send-Sstp "EXECUTE SSTP/1.1`r`nSender: CLI`r`nCommand: GetProperty`r`nCharset: UTF-8`r`nConnection: close`r`nReference0: $prop`r`n`r`n"

if ($p2 -match "^SSTP/1.\d 200") {
    # SSP の応答は NUL 終端。TrimEnd() は NUL を空白と見なさないので先に落とす
    Write-Output ($p2 -split "`r`n`r`n", 2)[1].Trim([char]0).TrimEnd()
} else {
    (Send-Sstp "SEND SSTP/1.4`r`nSender: CLI`r`nReceiverGhostName: $GhostName`r`nEvent: $Name`r`nCharset: UTF-8`r`nConnection: close`r`n`r`n") -split "`r`n" | 
        Where-Object { $_ -match "^Script:\s*(.*)" } | ForEach-Object { $Matches[1] }
}