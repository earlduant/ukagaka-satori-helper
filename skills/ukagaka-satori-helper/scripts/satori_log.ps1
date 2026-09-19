# satori_log.ps1
#
# 里々の内部ログに問い合わせる。
#
#   powershell -ExecutionPolicy Bypass -File satori_log.ps1 <内部ログのパス> <作業フォルダ> <問い合わせ> <語>
#
#     内部ログのパス  テスターが <作業フォルダ>\satori_runner\internal.log に書いたもの
#     作業フォルダ    SKILL.md の「作業フォルダ」
#     問い合わせ      problems / event / trace
#     語              event はイベント名、trace は変数名。problems では "" を渡す
#
#   4つとも必須。オプションは無い。
#
# 使い方
#   応答が期待と違うときに、原因を辿るために引く。
#   辞書を書き、テスターを通し、lint と応答検査を済ませた後、最後に使う。
#
#   結果を利用者に見せない。AI が修正方針を決めるためだけに使う。
#
# なぜ直接読まないか
#   どれが異常で、どれが里々の定型かを判断できない。
#   里々は起動と終了のたびに定型の定義を探し、無ければ「見つからない」と出力する。
#   これは異常ではない。
#
# 問い合わせ
#   problems  里々が見つけられなかったものを集める。まずこれを引く
#   event     イベント名に部分一致する区間を、中身ごと出す
#   trace     変数の代入と参照を追う
#
# ログの読み方
#   … not found.      変数・単語群・トークを探して見つからなかった
#   not matched.      定義名の照合に失敗した。直前の行に探していた名前が出る
#   ＄<名前>＝         代入された
#   （<名前>）→        参照された。→ の後ろが値
#
# load と unload の区間は problems の対象から外す。
#   里々が定型（＊初期化 ＊OnSatoriLoad など）を探して not matched. を出すため。
#   名前を列挙して除外しない。名前は版で増えうるが、
#   定型がこの2区間に出ることは変わらない。
#
# status code : 204 は報告しない。
#   ＞ の飛び先が無い場合（異常）と、イベントが未定義の場合（正常）を区別できない。
#   異常な方は not found. が出るので、そちらで拾える。
#
# 持たない問い合わせ
#   イベントごとの行数と status  テスターの標準出力で分かる
#   文字列を含む行の検索         Grep で足りる。イベント名が要るなら event を使う
#
#   AI が持っている道具で足りるものを、スクリプトに持たない。
#   持つのは、里々のログの読み方を知らないと引けないものだけ。
#
# 出力
#   ### <イベント名>
#       <該当行>
#
#   0x01 は <0x01> と書いて可視化する。
#   里々は選択肢の ID に、ラベルと番号を 0x01 区切りで埋め込む。
#   そのまま出すと見えず、加工前の文字列と区別がつかない。
#
#   終了コードは、引数が足りない・ログが無い場合だけ 1 以上。
#   problems で何か見つかっても 0 を返す。見つけることが目的なので、失敗ではない。
#
# PowerShellネイティブで処理する。コンパイルは行わない。
#
# このファイルは BOM 付き UTF-8 で保存する。
# PowerShell 5.1 は BOM の無い UTF-8 を ANSI として読むため、
# 日本語が壊れる。

param(
    [Parameter(Position = 0)] [string] $LogPath,
    [Parameter(Position = 1)] [string] $WorkDir,
    [Parameter(Position = 2)] [string] $Query,
    [Parameter(Position = 3)] [AllowEmptyString()] [string] $Word
)

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$usage = @'
里々の内部ログに問い合わせる。

  satori_log.ps1 <内部ログのパス> <作業フォルダ> <問い合わせ> <語>

    内部ログのパス  テスターが書いた internal.log
    作業フォルダ    SKILL.md の「作業フォルダ」
    問い合わせ      problems / event / trace
    語              event はイベント名、trace は変数名。problems では "" を渡す

  problems  里々が見つけられなかったものを集める。まずこれを引く
  event     イベント名に部分一致する区間を、中身ごと出す
  trace     変数の代入と参照を追う
'@

if (-not $LogPath -or -not $WorkDir -or -not $Query) { Write-Output $usage; exit 1 }
if (-not (Test-Path $LogPath)) { Write-Output "ログファイルがありません: $LogPath"; exit 2 }
if (($Query -eq 'event' -or $Query -eq 'trace') -and -not $Word) { Write-Output $usage; exit 1 }

function Load-SatoriLog {
    param([string]$path)
    $sections = [System.Collections.Generic.List[psobject]]::new()
    $seen = @{}
    $current = [pscustomobject]@{ Name = "(先頭)"; Lines = [System.Collections.Generic.List[string]]::new() }
    $sections.Add($current)

    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ($line -match '^=+ (.*?) =+$') {
            $raw = $matches[1]
            $name = $raw
            if ($seen.ContainsKey($raw)) {
                $seen[$raw]++
                $name = "$raw #$($seen[$raw])"
            } else {
                $seen[$raw] = 1
            }
            $current = [pscustomobject]@{ Name = $name; Lines = [System.Collections.Generic.List[string]]::new() }
            $sections.Add($current)
        } else {
            $current.Lines.Add($line)
        }
    }
    return $sections
}

function Get-Visible {
    param([string]$s)
    if ($s.IndexOf([char]1) -lt 0) { return $s }
    return $s.Replace([string][char]1, '<0x01>')
}

function Write-Hits {
    param([string]$name, $hits)
    if ($hits.Count -eq 0) { return }
    Write-Output "### $name"
    foreach ($h in $hits) { Write-Output "    $(Get-Visible $h)" }
    Write-Output ""
}

try {
    $sections = Load-SatoriLog (Resolve-Path $LogPath).Path
    
    switch ($Query) {
        'problems' {
            $found = 0
            foreach ($sec in $sections) {
                if ($sec.Name -eq 'load' -or $sec.Name -eq 'unload') { continue }
                $hits = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $sec.Lines.Count; $i++) {
                    $s = $sec.Lines[$i].Trim()
                    if ($s.IndexOf("not found.") -ge 0) {
                        $hits.Add($s)
                    } elseif ($s.EndsWith("not matched.")) {
                        $ctx = if ($i -gt 0) { $sec.Lines[$i - 1].Trim() } else { "" }
                        if ($ctx.Length -gt 0) { $hits.Add("$ctx  $s") } else { $hits.Add($s) }
                    }
                }
                if ($hits.Count -gt 0) { $found++ }
                Write-Hits $sec.Name $hits
            }
            if ($found -eq 0) { Write-Output "里々が見つけられなかったものはありません。" }
        }
        'event' {
            $found = 0
            foreach ($sec in $sections) {
                if ($sec.Name.IndexOf($Word) -lt 0) { continue }
                $found++
                Write-Output "### $($sec.Name)"
                foreach ($l in $sec.Lines) { Write-Output (Get-Visible $l) }
                Write-Output ""
            }
            if ($found -eq 0) { Write-Output "その名前を含む区間はありません: $Word" }
        }
        'trace' {
            $set = "＄$Word＝"
            $reference = "（$Word）→"
            $found = 0
            foreach ($sec in $sections) {
                $hits = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $sec.Lines) {
                    if ($line.IndexOf($set) -ge 0 -or $line.IndexOf($reference) -ge 0) {
                        $hits.Add($line.Trim())
                    }
                }
                if ($hits.Count -gt 0) { $found++ }
                Write-Hits $sec.Name $hits
            }
            if ($found -eq 0) { Write-Output "その変数は出てきません: $Word" }
        }
        default {
            exit 1
        }
    }
} catch {
    Write-Output "CRASH: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    Write-Output $_.Exception.StackTrace
    exit 5
}

