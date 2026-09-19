# satori_script.ps1
#
# 里々が返したさくらスクリプトが壊れていないかを検査する。
#
#   powershell -ExecutionPolicy Bypass -File satori_script.ps1 <テスターの出力ファイル> <作業フォルダ>
#
#     テスターの出力ファイル  satori_runner.ps1 の標準出力を保存したもの
#     作業フォルダ    SKILL.md の「作業フォルダ」
#
#   2つとも必須。オプションは無い。
#
# 役割の分担
#   里々   さくらスクリプト文字列を構築して返す。
#          タグでない部分は、そのままバルーンに表示される。
#   SSP    そのさくらスクリプトを解釈して実行する。
#
#   辞書が作るのは文字列までで、そこから先は SSP の仕事。
#   壊れた文字列を渡しても、SSP は黙って無視するか、意図しない表示をする。
#   里々もテスターも何も言わない。
#
# 使い方
#   テスターを通した後、自分が書いた辞書の出力を自分で検査する。
#   結果を利用者に見せない。修正方針を決めるためだけに使う。
#
#   応答を読むための道具ではない。戻り値を読むのはトークンの無駄。
#   問題があるときだけ報告する。何も無ければ件数行だけを出す。
#
#   見るのは「壊れていないか」だけ。
#   「リストを作って」のような自然文の要求を満たしたかは判定できない。
#   検査項目は、このスクリプトを書いた時点で決まっている。
#   そこに、まだ言われていない要求は入っていない。
#   そのときはテスターの出力を直接読む。このスクリプトは使わない。
#
# 入力の形式
#   テスターの出力から次の2つを読む。テスターの出力形式に依存する。
#   片方を変えたらもう片方も直す。
#
#     ========== <イベント名> ==========
#     Value: <さくらスクリプト>
#
#   同じイベント名が続くときは <名前> #2 <名前> #3 と番号を振る。
#
# 検査項目
#   [error] タグの [ が閉じていない（後続がすべて引数に飲まれる）
#   [error] \__q \_a が閉じられていない（そこから後ろが全部その範囲になる）
#   [warn ] \__q \_a が、開かれていないのに閉じられている
#   [warn ] 選択肢・アンカーの ID が空（どれを選んだか判別できない）
#   [warn ] \n の引数が half でもパーセントでもない（表示されずに消える）
#
# 検出しないもの
#   引数が空のタグ            空でも問題にならないタグがある。確実に言えない
#   展開されなかった （…）    φ（ で意図して出したものと区別できない。
#                             内部ログの not found で分かる
#   未実装のタグ              SSP の実装状況を持たない。持っても更新で古くなる
#   タグ名のタイポ            \f[heigh,100%] のような誤り
#   引数が必須のタグの引数なし \_q のつもりで \q と書くような誤り
#   \e が無い                 里々が自動で付ける
#   引数の値が範囲外          サーフェス番号はゴーストごとに違う。判定の根拠が無い
#
#   タイポと引数なしは、タグごとの仕様を持てば取れる。持たないのは、
#   さくらスクリプトが SSP の機能で、版ごとにタグが増えるため。
#   一覧が古くなると、正常な辞書に「誤り」と言うことになる。
#
#   検査器は、間違ったことを言わない限り、不完全でよい。
#   見逃しは検査しなかったのと同じだが、誤情報は辞書を壊す。
#
# 出力
#   <イベント名>: [<水準>] <内容>
#       > <抜粋>
#
#   位置を文字数で報告しない。修正するのは辞書であって応答ではない。
#   抜粋は辞書を grep して場所を特定するために出す。
#
#   終了コードは error があれば 1、無ければ 0。
#
# PowerShellネイティブで処理する。コンパイルは行わない。
#
# このファイルは BOM 付き UTF-8 で保存する。
# PowerShell 5.1 は BOM の無い UTF-8 を ANSI として読むため、
# 日本語が壊れる。

param(
    [Parameter(Position = 0)] [string] $ResultFile,
    [Parameter(Position = 1)] [string] $WorkDir
)

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$usage = @'
里々が返したさくらスクリプトが壊れていないかを検査する。

  satori_script.ps1 <テスターの出力ファイル> <作業フォルダ>

    テスターの出力ファイル  satori_runner.ps1 の標準出力を保存したもの
    作業フォルダ    SKILL.md の「作業フォルダ」

  問題があるときだけ報告する。応答を読むための道具ではない。
'@

if (-not $ResultFile -or -not $WorkDir) { Write-Output $usage; exit 2 }
if (-not (Test-Path $ResultFile)) { Write-Output "ファイルがありません: $ResultFile"; exit 2 }

function Get-SatoriTags {
    param([string]$s)
    $REGEX_TAG = [regex]'\\_{0,2}[a-zA-Z0-9*!\?&\-\+](\d|\[("([^"]|\\")+?"|([^\]]|\\\])+?)+?\])?'
    $REGEX_NAME = [regex]'\G\\(_{0,2}[a-zA-Z0-9*!\?&\-\+])'
    $NO_ARG = [Collections.Generic.HashSet[string]]::new([string[]]("0 1 4 5 6 7 a e h t u v z * - + C _! _? _+ _n _q _V __c".Split(' ')))

    $tags = [System.Collections.Generic.List[psobject]]::new()
    $i = 0
    while ($i -lt $s.Length) {
        $nm = $REGEX_NAME.Match($s, $i)
        if (-not $nm.Success) {
            $i++
            continue
        }
        $name = $nm.Groups[1].Value
        $afterName = $nm.Index + $nm.Length
        $arg = $null
        $unclosed = $false
        $next = $afterName

        if (-not $NO_ARG.Contains($name)) {
            $m = $REGEX_TAG.Match($s, $i)
            if ($m.Success -and $m.Index -eq $i -and $m.Groups[1].Success) {
                $raw = $m.Groups[1].Value
                $arg = if ($raw.StartsWith('[')) { $raw.Substring(1, $raw.Length - 2) } else { $raw }
                $next = $m.Index + $m.Length
            } elseif ($afterName + 1 -lt $s.Length -and $s[$afterName] -eq '[' -and $s[$afterName + 1] -eq ']') {
                $arg = ""
                $next = $afterName + 2
            } elseif ($afterName -lt $s.Length -and $s[$afterName] -eq '[') {
                $arg = $s.Substring($afterName + 1)
                $unclosed = $true
                $next = $s.Length
            }
        }
        $tags.Add([pscustomobject]@{ Name = $name; Arg = $arg; Pos = $i; Unclosed = $unclosed })
        $i = $next
    }
    return $tags
}

function Check-SatoriTags {
    param($tags)
    $problems = [System.Collections.Generic.List[psobject]]::new()
    
    foreach ($t in $tags) {
        if ($t.Unclosed) {
            $problems.Add([pscustomobject]@{ Level = 'error'; Pos = $t.Pos; Text = "\$($t.Name)[ が閉じていない。後続がすべて引数に飲まれる" })
        }
    }
    
    foreach ($name in '__q', '_a') {
        $depth = 0
        $lastOpen = 0
        foreach ($t in $tags) {
            if ($t.Name -ne $name) { continue }
            if ($null -ne $t.Arg) {
                $depth++; $lastOpen = $t.Pos
            } else {
                $depth--
                if ($depth -lt 0) {
                    $problems.Add([pscustomobject]@{ Level = 'warn'; Pos = $t.Pos; Text = "\$name が、開かれていないのに閉じられている" })
                    $depth = 0
                }
            }
        }
        if ($depth -gt 0) {
            $problems.Add([pscustomobject]@{ Level = 'error'; Pos = $lastOpen; Text = "\$name が $depth 個、閉じられていない。そこから後ろが全部その範囲になる" })
        }
    }
    
    foreach ($t in $tags) {
        if ($t.Name -notmatch '^(q|__q|_a)$' -or $null -eq $t.Arg -or $t.Unclosed) { continue }
        $parts = $t.Arg.Split(',')
        $id = if ($t.Name -eq 'q') { if ($parts.Length -gt 1) { $parts[1] } else { "" } } else { $parts[0] }
        if ([string]::IsNullOrWhiteSpace($id)) {
            $problems.Add([pscustomobject]@{ Level = 'warn'; Pos = $t.Pos; Text = "\$($t.Name) の ID が空。どれを選んだか判別できない" })
        }
    }
    
    $PERCENT = [regex]'^-?[0-9]+$'
    foreach ($t in $tags) {
        if ($t.Name -ne 'n' -or [string]::IsNullOrEmpty($t.Arg) -or $t.Unclosed) { continue }
        if ($t.Arg -eq 'half' -or $PERCENT.IsMatch($t.Arg)) { continue }
        $problems.Add([pscustomobject]@{ Level = 'warn'; Pos = $t.Pos; Text = "\n[$($t.Arg)] は改行の指定になっていない。[$($t.Arg)] は表示されずに消える（表示したいなら ［ を全角にする）" })
    }
    
    if ($problems.Count -gt 0) {
        $problems.Sort({ param($a, $b) $a.Pos - $b.Pos })
    }
    return $problems
}

function Load-SatoriInput {
    param([string]$path)
    $list = [System.Collections.Generic.List[psobject]]::new()
    $seen = @{}
    $current = "(先頭)"
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ($line -match '^=+ (.*?) =+$') { $current = $matches[1]; continue }
        if ($line -match '^Value:\s?(.*)$') {
            $name = $current
            if ($seen.ContainsKey($current)) {
                $seen[$current]++
                $name = "$current #$($seen[$current])"
            } else {
                $seen[$current] = 1
            }
            $list.Add([pscustomobject]@{ Name = $name; Script = $matches[1] })
        }
    }
    return $list
}

function Get-Excerpt {
    param([string]$script, [int]$pos)
    $from = [Math]::Max(0, $pos - 40)
    $to = [Math]::Min($script.Length, $pos + 40)
    $head = if ($from -gt 0) { "…" } else { "" }
    $tail = if ($to -lt $script.Length) { "…" } else { "" }
    return $head + $script.Substring($from, $to - $from) + $tail
}

$exitCode = 0
try {
    $responses = Load-SatoriInput $ResultFile
    if ($responses.Count -eq 0) {
        Write-Output "Value: の行が見つからない。テスターの出力を渡す: $ResultFile"
        $exitCode = 2
    } else {
        $errors = 0
        $warns = 0

        $output = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $responses) {
            $tags = Get-SatoriTags $r.Script
            $problems = Check-SatoriTags $tags
            foreach ($p in $problems) {
                if ($p.Level -eq 'error') { $errors++ } else { $warns++ }
                $lvl = if ($p.Level -eq 'error') { "error" } else { "warn " }
                $output.Add("$($r.Name): [$lvl] $($p.Text)")
                $output.Add("    > $(Get-Excerpt $r.Script $p.Pos)")
            }
        }

        $output.Add("error $errors 件 / warn $warns 件")
        
        # 完全にパイプラインに出力しきる
        $output | ForEach-Object { Write-Output $_ }
        if ($errors -gt 0) { $exitCode = 1 } else { $exitCode = 0 }
    }
} catch {
    Write-Output "CRASH: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    Write-Output $_.Exception.StackTrace
    $exitCode = 5
}

exit $exitCode


