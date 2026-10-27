# satori_lint.ps1
#
# 辞書を実行せずに検査する。
#
#   powershell -ExecutionPolicy Bypass -File satori_lint.ps1 <ghost/master>
#
# 使い方
#   辞書を書き換えるたびに、テスターより先に通す。
#   本番の ghost/master を渡す。読むだけで、書き換えない。
#   **結果を利用者に見せない。**修正方針を決めるためだけに使う。
#   利用者が意図して書いたかどうかを判別できないので、検出したものをそのまま「誤り」として提示しない。
#
# 出力
#   1件1行で、里々の lint（ShioriLint）と同じ形。ファイルと行の順に並べる。
#
#     ファイル(行) : error/warning/notice: 説明文
#
#   自前の検査と里々の lint の結果を、同じ一覧に混ぜる。error があれば終了コード 1。
#   里々の lint が無い版と、その結果を取れなかったときは、先頭にそう出す。
#
# 自前の検査
#   ghost/master の下の dic*.txt を、サブフォルダも含めてすべて見る。
#   [error]   if / iflist / unless / switch / nswitch / choice の枝に処理がある（両方の枝が実行される）
#             処理とみなすのは set・単語の追加・追加単語の削除・追加単語の全削除と、
#             それを含む定義を呼ぶ call / loop / vncall。値を返すだけの定義を呼ぶものは報告しない
#   [warning] 上の枝で、呼び先が判定できない call がある（動的な名前、辞書に無い名前）
#   [error]   遅延する関数の引数がカッコで区切られている（if と同じ動作になる）
#   [error]   閉じていない（ が次の ＊ ＠ の行を飲み込んでいる（間の定義が消える）
#   [warning] スコープ（： \0 \1）の直後と、トークの最初の行の行頭に半角 [ がある（タグの引数になる）
#   [warning] トークの2行目以降の行頭に半角 [ がある（ウェイトが入らないと \n[…] となり、\n の引数になる）
#   [warning] 採用条件がタブで区切られていない（条件が名前の一部になる）
#   [error]   採用条件が数値にならない文字列（常に偽で、その定義は選ばれない）
#   [warning] 同名定義に、（乱数…）を含む採用条件が丸ごと同じ記述で2回以上ある（1回しか評価されない）
#   [notice]  括弧の中の字下げがタブでない（空白が引数に残る。表示のための字下げもある）
#   [error]   行頭の ＄ ＞ の直後、タブの無い ＿ の直後が半角か全角の空白（空白込みの名前になる）
#   [error]   ＝ / = の手前が空白（代入されない）
#   [warning] タブ区切りの代入で、（名前）と数を演算子でつないでいる（式が文字列のまま入り、
#             別の計算に使うと演算の順序がずれる）
#   [error]   上のうち、自分自身を含むもの（呼ぶたびに式が伸びる）
#   [warning] 変数・単語群・トークで同じ名前を使っている（片方が読めなくなる）
#   [error]   開きカッコが末尾まで閉じていない（そこから後ろの定義が無効になる。そのファイルのほかの検査は行わない）
#   [warning] 閉じカッコが過剰。φ（ と対になる ）と、１） a） のような番号は数えない
#
#   里々が読むのと同じ文字列を検査する。φ の次の1文字は文字として扱い、replace.txt は行ごとに適用する
#   （行番号を本番と合わせるため）。文字コードは里々の決まりで決める。
#     satori_bootconf.txt で UTF-8 に固定されていれば UTF-8
#     （辞書は is_utf8_dic、replace.txt は is_utf8_replace。is_utf8_all は両方に効く）
#     ACP 版（Mc1XX）: それ以外は Shift_JIS。BOM 付きのファイルは検査しない
#     Unicode 版（Mc2XX）: BOM 付きか、UTF-8 の規則に反するバイト列がなければ UTF-8。それ以外は Shift_JIS
#
# 里々の lint
#   satori.dll の中に ShioriLint の名前がある版（Mc206-1 以降）でだけ行う。
#   古い版は読み込まない。Mc162 以前は、辞書にエラーがあると OK を押すまで止まるダイアログを出すため。
#   一時フォルダに satori.dll と辞書・設定だけをコピーし、テスターで送る。本番では動かさない。
#   里々は終了のときに satori_savedata.txt を書き、読み込みと終了のときに辞書のイベントを実行するため。
#   saori\ はコピーしない（ShioriLint は SAORI の名前を ＠SAORI から知る。SAORI を動かさないため）。
#
#   見ないもの：セーブデータにしか無い変数（「見つかりません」と出る）と、＄辞書フォルダ で切り替える先の辞書。
#   切り替え先は、テスターの seq.txt で切り替えるイベントの後に [ShioriLint] を送って見る。
#   結果は応答の ErrorDescription: に、バイト値 1 で区切って並ぶ。
#
# 事前のビルドは要らない。実行時に Add-Type がコンパイルする。
#
# このファイルは BOM 付き UTF-8 で保存する。
# PowerShell 5.1 は BOM の無い UTF-8 を ANSI として読むため、
# 日本語が壊れ、C# のコンパイルも通らなくなる。

param(
    [Parameter(Position = 0)] [string] $MasterDir
)

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$usage = @'
辞書を実行せずに検査する。

  satori_lint.ps1 <ghost/master>

    結果は利用者に見せない。修正方針を決めるためだけに使う。
'@

if (-not $MasterDir) { Write-Output $usage; exit 1 }
if (-not (Test-Path $MasterDir)) { Write-Output "見つかりません: $MasterDir"; exit 1 }
if (-not (Test-Path (Join-Path $MasterDir 'satori.dll'))) { Write-Output "satori.dll がありません: $MasterDir"; exit 1 }

$code = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Text.RegularExpressions;

public class SatoriLint
{
    // -----------------------------------------------------------------------
    // 里々の仕様。ここだけを直せば全検査に反映される
    // -----------------------------------------------------------------------

    // 引数区切り。＄引数区切り追加 は追わない（eval とグローバル変数のため追いきれない）
    static readonly char[] DELIMS = { '、', '､', '，', ',', (char)0x01 };

    // 引数の展開を遅延する関数。区切りがカッコだと遅延が効かない
    static readonly string[] LAZY = { "when", "whenlist", "for", "times", "while" };

    // 遅延しない関数。枝に副作用があると両方実行される
    static readonly string[] EAGER = { "if", "iflist", "unless", "switch", "nswitch", "choice" };

    // 枝が第1引数から始まる関数（他は第2引数から。第1引数は条件や比べる値）
    static readonly string[] ALL_ARGS_BRANCH = { "choice" };

    // それ自体が副作用を持つ関数
    static readonly Regex SIDE_EFFECT = new Regex(@"（(set|単語の追加|追加単語の削除|追加単語の全削除)[、､，,\x01（]");

    // 定義を呼ぶ関数。呼び先に副作用があるかを辿る
    static readonly Regex CALLER = new Regex(@"（(call|loop|vncall)([、､，,\x01])");

    // 呼び先の定義の本文。名前 → 本文（同名は全部）
    static Dictionary<string, List<string>> defs = new Dictionary<string, List<string>>();

    // ＄への代入の区切り
    static readonly Regex ASSIGN = new Regex(@"^＄([^\t＝=]*)([\t＝=])(.*)$");

    // 計算式とみなす演算子
    static readonly char[] OPERATORS = { '+', '-', '*', '/', '%', '＋', '－', '×', '÷', '％' };

    // 比較演算子
    static readonly Regex COMPARE = new Regex(@"==|!=|>=|<=|＝＝|！＝|＞＝|＜＝|>|<|＞|＜");

    // スコープ（：、\0、\1）の直後の半角 [
    static readonly Regex SCOPE_BRACKET = new Regex(@"：\[|(?<!\\)\\[01]\[");

    // 採用条件の中の乱数
    static readonly Regex RANDOM = new Regex(@"[（(]乱数[^（）()]*[）)]");

    // 先頭から数値として読めるか（strtol 相当）
    static readonly Regex LEADING_NUM = new Regex(@"^\s*[+-]?[0-9０-９]");

    // -----------------------------------------------------------------------

    class Node { public int Start, End; }

    // 1件1行。里々の lint と同じ形「ファイル(行) : ErrorLevel の値: 説明文」
    static List<string> issues = new List<string>();
    public static int ErrorCount = 0;

    static void Add(string file, int line, string level, string msg)
    {
        issues.Add(file + "(" + line + ") : " + level + ": " + msg);
        if (level == "error") { ErrorCount++; }
    }

    // -----------------------------------------------------------------------
    // replace.txt の適用。行ごとに置換して行番号を保つ
    // -----------------------------------------------------------------------



    // -----------------------------------------------------------------------
    // 低レベル
    // -----------------------------------------------------------------------

    // 全角＃から行末までをコメントとして除去する（文字数は保つ）
    static string StripComments(string text)
    {
        string[] lines = text.Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            int p = lines[i].IndexOf('＃');
            if (p != -1) { lines[i] = lines[i].Substring(0, p) + new string(' ', lines[i].Length - p); }
        }
        return string.Join("\n", lines);
    }

    static List<int> BuildLineStarts(string text)
    {
        List<int> starts = new List<int>();
        starts.Add(0);
        for (int i = 0; i < text.Length; i++) { if (text[i] == '\n') { starts.Add(i + 1); } }
        return starts;
    }

    static int LineOf(List<int> starts, int pos)
    {
        int lo = 0, hi = starts.Count - 1;
        while (lo < hi) { int mid = (lo + hi + 1) / 2; if (starts[mid] <= pos) { lo = mid; } else { hi = mid - 1; } }
        return lo + 1;
    }

    // φ の次の文字の代わりに置く印（私用領域）。括弧やコメントとして数えないため
    const char ESC_OPEN = '\uE000', ESC_CLOSE = '\uE001', ESC_HASH = '\uE002', ESC_PHI = '\uE003';

    // φ の次の1文字を印に置き換える。文字数は変えない
    static string MaskEscapes(string text)
    {
        StringBuilder sb = new StringBuilder(text);
        for (int i = 0; i + 1 < sb.Length; i++)
        {
            if (sb[i] != 'φ') { continue; }
            char c = sb[i + 1];
            if (c == '（') { sb[i + 1] = ESC_OPEN; }
            else if (c == '）') { sb[i + 1] = ESC_CLOSE; }
            else if (c == '＃') { sb[i + 1] = ESC_HASH; }
            else if (c == 'φ') { sb[i + 1] = ESC_PHI; }
            i++;
        }
        return sb.ToString();
    }

    static string Visible(string s)
    {
        return s.Replace("\t", "⇥").Replace("\r", "").Replace("\n", "⏎")
            .Replace(ESC_OPEN, '（').Replace(ESC_CLOSE, '）').Replace(ESC_HASH, '＃').Replace(ESC_PHI, 'φ');
    }

    // 括弧の対応。φ（ φ） は MaskEscapes で印になっているので数えない。
    // 対応する（ の無い ） のうち、同じ行の φ（ と対になるものと、１） a） のような番号は過剰としない
    static void ScanParens(string text, List<Node> nodes, List<int> unclosed, List<int> orphan)
    {
        List<int> stack = new List<int>();
        int escapedOpen = 0;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (c == '\n') { escapedOpen = 0; continue; }
            if (c == ESC_OPEN) { escapedOpen++; continue; }
            if (c != '（' && c != '）') { continue; }
            if (c == '（') { stack.Add(i); }
            else
            {
                if (stack.Count == 0)
                {
                    if (escapedOpen > 0) { escapedOpen--; }
                    else if (i == 0 || !IsListMarker(text[i - 1])) { orphan.Add(i); }
                }
                else
                {
                    Node n = new Node();
                    n.Start = stack[stack.Count - 1];
                    n.End = i;
                    stack.RemoveAt(stack.Count - 1);
                    nodes.Add(n);
                }
            }
        }
        unclosed.AddRange(stack);
    }

    // 里々が読み飛ばすのは改行と、括弧の中の行頭タブだけ
    static bool IsSkip(string s, int i)
    {
        char c = s[i];
        if (c == '\r' || c == '\n') { return true; }
        if (c != '\t') { return false; }
        for (int j = i - 1; j >= 0; j--)
        {
            if (s[j] == '\n' || s[j] == '\r') { return true; }
            if (s[j] != '\t') { return false; }
        }
        return false;
    }

    static bool IsDelim(char c)
    {
        foreach (char d in DELIMS) { if (c == d) { return true; } }
        return false;
    }

    // 括弧の中身から関数名を取り出す
    static string FuncName(string body)
    {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < body.Length && sb.Length < 32; i++)
        {
            char ch = body[i];
            if (IsDelim(ch) || ch == '（' || ch == '）' || ch == '\\') { break; }
            if (IsSkip(body, i)) { continue; }
            sb.Append(ch);
        }
        return sb.ToString();
    }

    static bool In(string[] set, string name)
    {
        foreach (string s in set) { if (s == name) { return true; } }
        return false;
    }

    // 先頭から数値として読めるか
    static bool LooksNumeric(string s)
    {
        return LEADING_NUM.IsMatch(s);
    }

    static bool HasOperator(string s)
    {
        foreach (char c in OPERATORS) { if (s.IndexOf(c) >= 0) { return true; } }
        return false;
    }

    static bool IsDigitChar(char c)
    {
        return (c >= '0' && c <= '9') || (c >= '０' && c <= '９');
    }

    static bool IsListMarker(char c)
    {
        return IsDigitChar(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= 'ａ' && c <= 'ｚ') || (c >= 'Ａ' && c <= 'Ｚ');
    }

    // 括弧の外（地の文）に、計算のつもりの演算子があるか。
    // 演算子の片側が数、反対側が全角括弧の参照のときだけ真（（カウンタ）＋１ の形）。
    static bool HasCalcOperator(string val)
    {
        int depth = 0;
        for (int i = 0; i < val.Length; i++)
        {
            char c = val[i];
            if (c == '（') { depth++; continue; }
            if (c == '）') { depth--; continue; }
            if (depth > 0 || Array.IndexOf(OPERATORS, c) < 0) { continue; }

            int l = i - 1; while (l >= 0 && IsSpace(val[l])) { l--; }
            int r = i + 1; while (r < val.Length && IsSpace(val[r])) { r++; }
            if (l < 0 || r >= val.Length) { continue; }
            char p = val[l], n = val[r];
            if ((p == '）' && IsDigitChar(n)) || (IsDigitChar(p) && n == '（')) { return true; }
        }
        return false;
    }

    // 括弧の中身を引数に分ける。区切りは関数名の直後に最初に出た区切り文字に固定される
    static List<string> SplitArgs(string body, string fn)
    {
        List<string> args = new List<string>();
        string rest = body.Substring(fn.Length);
        char delim = '\0';
        int depth = 0;
        for (int i = 0; i < rest.Length; i++)
        {
            char c = rest[i];
            if (i > 0 && rest[i - 1] == 'φ') { continue; }
            if (c == '（') { depth++; }
            else if (c == '）') { depth--; }
            else if (depth == 0 && IsDelim(c)) { delim = c; break; }
        }
        if (delim == '\0') { return args; }

        StringBuilder cur = null;
        depth = 0;
        for (int i = 0; i < rest.Length; i++)
        {
            char c = rest[i];
            bool esc = (i > 0 && rest[i - 1] == 'φ');
            if (!esc && c == '（') { depth++; }
            else if (!esc && c == '）') { depth--; }
            if (depth == 0 && c == delim && !esc)
            {
                if (cur != null) { args.Add(cur.ToString()); }
                cur = new StringBuilder();
                continue;
            }
            if (cur != null) { cur.Append(c); }
        }
        if (cur != null) { args.Add(cur.ToString()); }
        return args;
    }

    // 文字列の中に副作用があるか。
    // 0 なし / 1 あり / 2 判定できない。what に何が見つかったかを入れる
    static int FindEffect(string s, int level, HashSet<string> visiting, out string what)
    {
        what = null;
        Match m = SIDE_EFFECT.Match(s);
        if (m.Success) { what = m.Groups[1].Value; return 1; }

        int unknown = 0;
        string unknownWhat = null;
        foreach (Match c in CALLER.Matches(s))
        {
            int p = c.Index + c.Length;
            if (p < s.Length && s[p] == '（')
            {
                unknown = 2; unknownWhat = c.Groups[1].Value + "（名前が動的）";
                continue;
            }
            StringBuilder nm = new StringBuilder();
            while (p < s.Length && !IsDelim(s[p]) && s[p] != '）' && s[p] != '（') { nm.Append(s[p]); p++; }
            string name = nm.ToString().Trim();
            if (name.Length == 0) { continue; }

            List<string> bodies;
            if (!defs.TryGetValue(name, out bodies))
            {
                unknown = 2; unknownWhat = c.Groups[1].Value + " " + name + "（辞書に無い）";
                continue;
            }
            if (level >= 8 || visiting.Contains(name)) { continue; }
            visiting.Add(name);
            foreach (string b in bodies)
            {
                string inner;
                // 呼び先の ＄ の行は代入
                if (Regex.IsMatch(b, @"(^|\n)＄")) { what = c.Groups[1].Value + " " + name + " の中の ＄"; visiting.Remove(name); return 1; }
                int r = FindEffect(b, level + 1, visiting, out inner);
                if (r == 1) { what = c.Groups[1].Value + " " + name + " の中の " + inner; visiting.Remove(name); return 1; }
                if (r == 2 && unknown == 0) { unknown = 2; unknownWhat = c.Groups[1].Value + " " + name + " の中の " + inner; }
            }
            visiting.Remove(name);
        }
        if (unknown == 2) { what = unknownWhat; }
        return unknown;
    }

    // 定義の本文を集める（call の呼び先を辿るため）
    static void CollectDefs(string[] lines)
    {
        string name = null;
        StringBuilder body = null;
        for (int i = 0; i <= lines.Length; i++)
        {
            string line = (i < lines.Length) ? lines[i].TrimEnd('\r') : null;
            bool head = (line == null) || (line.Length > 0 && (line[0] == '＊' || line[0] == '＠'));
            if (!head) { if (body != null) { body.Append(line).Append('\n'); } continue; }
            if (name != null)
            {
                if (!defs.ContainsKey(name)) { defs[name] = new List<string>(); }
                defs[name].Add(body.ToString());
            }
            if (line == null) { break; }
            int tab = line.IndexOf('\t');
            name = (tab < 0 ? line.Substring(1) : line.Substring(1, tab - 1)).Trim();
            body = new StringBuilder();
        }
    }

    static bool IsSpace(char c)
    {
        return c == ' ' || c == '　' || c == '\t';
    }

    // -----------------------------------------------------------------------
    // 検査
    // -----------------------------------------------------------------------

    static void CheckParens(string name, string text, string[] lines, List<int> lineStarts,
                            List<int> unclosed, List<int> orphan)
    {
        foreach (int pos in unclosed)
        {
            Add(name, LineOf(lineStarts, pos), "error",
                "開きカッコ「（」に対応する「）」がありません。この定義からファイルの末尾までが無効になります。このファイルのほかの検査は行っていません。");
        }
        foreach (int pos in orphan)
        {
            Add(name, LineOf(lineStarts, pos), "warning",
                "対応する「（」のない閉じカッコ「）」があります。里々は影響を受けませんが、入れ子の書き間違いの疑いがあります。");
        }
    }

    // 括弧が ＊ ＠ の行をまたいでいる。閉じ忘れが、後ろの別の「）」と対になった形。
    // 里々は報告せず、間の定義が台詞として飲み込まれる
    static void CheckSwallow(string name, string text, List<int> lineStarts, List<Node> nodes)
    {
        List<Node> spans = new List<Node>();
        foreach (Node n in nodes)
        {
            string inner = text.Substring(n.Start, n.End - n.Start);
            if (inner.IndexOf("\n＊") >= 0 || inner.IndexOf("\n＠") >= 0) { spans.Add(n); }
        }
        spans.Sort(delegate(Node a, Node b) { return a.Start.CompareTo(b.Start); });
        int lastEnd = -1;
        foreach (Node n in spans)
        {
            if (n.Start < lastEnd) { continue; }
            lastEnd = n.End;
            Add(name, LineOf(lineStarts, n.Start), "error",
                "閉じていない「（」が、" + LineOf(lineStarts, n.End) + "行目の「）」まで続いています。"
                + "間にある ＊ ＠ の定義は読まれず、台詞として表示されます。里々は報告しません。");
        }
    }

    // 1 枝の副作用 / 2 カッコ区切り / 6 字下げ
    static void CheckNodes(string name, string text, List<int> lineStarts, List<Node> nodes)
    {
        foreach (Node node in nodes)
        {
            string body = text.Substring(node.Start + 1, node.End - node.Start - 1);
            string fn = FuncName(body);
            int line = LineOf(lineStarts, node.Start);

            // 1 枝の副作用
            if (In(EAGER, fn))
            {
                List<string> args = SplitArgs(body, fn);
                int from = In(ALL_ARGS_BRANCH, fn) ? 0 : 1;
                int found = 0;
                string what = null;
                for (int a = from; a < args.Count && found != 1; a++)
                {
                    string w;
                    int r = FindEffect(args[a], 0, new HashSet<string>(), out w);
                    if (r == 1 || (r == 2 && found == 0)) { found = r; what = w; }
                }
                if (found == 1)
                {
                    Add(name, line, "error",
                        fn + " の枝に処理（" + what + "）があります。" + fn
                        + " は選ばれなかった枝も実行するので、when / whenlist を使ってください。");
                }
                else if (found == 2)
                {
                    Add(name, line, "warning",
                        fn + " の枝に、呼び先を判定できない呼び出し（" + what + "）があります。"
                        + "呼び先に処理があれば、選ばれなかった枝でも実行されます。");
                }
            }

            // 2 カッコ区切り
            if (In(LAZY, fn))
            {
                string rest = body.Substring(fn.Length);
                int h = 0;
                while (h < rest.Length && IsSkip(rest, h)) { h++; }
                bool hasDelim = false;
                int depth = 0;
                for (int i = 0; i < rest.Length; i++)
                {
                    char c = rest[i];
                    if (i > 0 && rest[i - 1] == 'φ') { continue; }
                    if (c == '（') { depth++; }
                    else if (c == '）') { depth--; }
                    else if (depth == 0 && IsDelim(c)) { hasDelim = true; break; }
                }
                if (!hasDelim && h < rest.Length && rest[h] == '（')
                {
                    Add(name, line, "error",
                        fn + " の引数がカッコで区切られています。区切りが展開後に決まるため遅延が効かず、if と同じ動作になります。");
                }
            }

            // 6 字下げ（括弧の中で、改行の直後にタブ以外の空白）
            for (int i = 1; i < body.Length; i++)
            {
                if (body[i - 1] != '\n') { continue; }
                if (body[i] == ' ' || body[i] == '　')
                {
                    Add(name, LineOf(lineStarts, node.Start + 1 + i), "notice",
                        "括弧の中の字下げにタブ以外の空白が使われています。里々が読み飛ばすのは行頭タブだけなので、空白が引数に残ります。");
                    break;
                }
            }
        }
    }

    // 3 条件の区切り / 4 文字列条件 / 7 記号の直後 / 8 ＝の手前 / 9 タブ代入の式 / 12 スコープ直後の[ / 13 行頭の[
    static void CheckLines(string name, string[] lines)
    {
        bool inTalk = false;
        bool bodyStarted = false;   // トークの本文で、文字を出す行がもう現れたか
        int depth = 0;
        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i].TrimEnd('\r');
            int depthAtStart = depth;
            foreach (char c in line)
            {
                if (c == '（') { depth++; }
                else if (c == '）' && depth > 0) { depth--; }
            }
            if (line.Length == 0) { continue; }
            char head = line[0];
            int ln = i + 1;

            bool isHeader = (head == '＊' || head == '＠');
            if (head == '＊') { inTalk = true; bodyStarted = false; }
            else if (head == '＠') { inTalk = false; }

            // 12 スコープの直後の半角 [。トークの最初の行の [ も、里々が前に \0 \1 を入れるので同じになる
            bool firstBracket = (head == '[' && inTalk && !bodyStarted && depthAtStart == 0);
            if ((head != '＄' && !isHeader && SCOPE_BRACKET.IsMatch(line)) || firstBracket)
            {
                Add(name, ln, "warning",
                    "スコープ（： \\0 \\1）の直後に半角 [ があります。トークの最初の行の [ も、里々が前にスコープを入れるので同じです。"
                    + "里々がタグの引数として扱い、ほかに文字が無いと応答が 204 になります。全角の括弧にしてください。");
            }

            // 13 トークの2行目以降の行頭の半角 [。括弧の中の行は前の行とつながるので数えない
            if (head == '[' && inTalk && bodyStarted && depthAtStart == 0)
            {
                Add(name, ln, "warning",
                    "トークの本文の行頭に半角 [ があります。里々はこの行の前に改行（\\n）を入れます。"
                    + "間に自動ウェイトが入らないとき（ウェイトを止めている、古い里々）は \\n[…] となり、"
                    + "[ から ] までが \\n の引数として読まれて表示されません。全角の括弧にしてください。");
            }

            // 文字を出す行。＄ の代入と ＞ ≫ ≧ のジャンプは出さない
            if (inTalk && !isHeader && depthAtStart == 0 && head != '＄' && head != '＞' && head != '≫' && head != '≧') { bodyStarted = true; }

            // 7 記号の直後が空白。タブは区切り（＞【タブ】条件 は名前の無いトークへのジャンプ）。
            // ＿ はタブが無いときだけ。タブがあれば ＿ の後は表示する文字で、名前にならない
            if (head == '＄' || head == '＞' || (head == '＿' && line.IndexOf('\t') < 0))
            {
                if (line.Length > 1 && (line[1] == ' ' || line[1] == '　'))
                {
                    Add(name, ln, "error",
                        head + " の直後が空白です。空白込みの名前になるので、空白なしの名前では読めません。");
                    continue;
                }
            }

            // ＄行の解析
            if (head == '＄')
            {
                Match m = ASSIGN.Match(line);
                if (m.Success)
                {
                    string vname = m.Groups[1].Value;
                    char sep = m.Groups[2].Value[0];
                    string val = m.Groups[3].Value;

                    // 8 ＝の手前が空白
                    if ((sep == '＝' || sep == '=') && vname.Length > 0 && IsSpace(vname[vname.Length - 1]))
                    {
                        Add(name, ln, "error",
                            "＝ の手前に空白があります。里々は代入しません。");
                    }

                    // 9 タブ区切りの代入に式
                    if (sep == '\t' && HasCalcOperator(val))
                    {
                        string self = "（" + vname + "）";
                        if (val.Contains(self) || val.Contains("(" + vname + ")"))
                        {
                            Add(name, ln, "error",
                                "タブ代入の自己参照に計算されない演算子があります。数式が文字列として際限なく伸びます。＝ を使ってください。");
                        }
                        else
                        {
                            Add(name, ln, "warning",
                                "タブ区切りの代入に計算されない演算子があります。数式が文字列として格納されます。＝ か calc を使ってください。");
                        }
                    }
                }
                continue;
            }

            // ＊ ＠ ＞ 行
            if (head == '＊' || head == '＠' || head == '＞')
            {
                int tab = line.IndexOf('\t');

                // 3 条件の区切り
                if (tab < 0)
                {
                    // 比較演算子があれば、条件を書いたつもりで区切れていない
                    bool hit = COMPARE.IsMatch(line.Substring(1));
                    if (!hit)
                    {
                        // 空白の後に括弧があれば、条件のつもりの疑い
                        for (int k = 1; k < line.Length; k++)
                        {
                            if (line[k] == ' ' || line[k] == '　')
                            {
                                if (line.Substring(k).IndexOf('（') >= 0) { hit = true; }
                                break;
                            }
                        }
                    }
                    if (hit)
                    {
                        Add(name, ln, "warning",
                            "採用条件がタブで区切られていません。条件が名前の一部として扱われます。");
                    }
                    continue;
                }

                // 4 文字列条件（＊ ＠ のみ）
                if (head == '＊' || head == '＠')
                {
                    string cond = line.Substring(tab + 1).Trim();
                    if (cond.Length > 0
                        && cond.IndexOf('（') < 0
                        && !HasOperator(cond)
                        && !COMPARE.IsMatch(cond)
                        && !LooksNumeric(cond))
                    {
                        Add(name, ln, "error",
                            "採用条件が数値になりません。0 とみなされ、常に偽になります。");
                    }
                }
            }
        }
    }

    // 5 乱数の共有。採用条件の記述が丸ごと同じものだけが1回の評価を共有する
    static void CheckRandom(string name, string[] lines)
    {
        Dictionary<string, Dictionary<string, List<int>>> byName =
            new Dictionary<string, Dictionary<string, List<int>>>();

        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i].TrimEnd('\r');
            if (line.Length == 0) { continue; }
            if (line[0] != '＊' && line[0] != '＠') { continue; }
            int tab = line.IndexOf('\t');
            if (tab < 0) { continue; }

            string defName = line.Substring(0, tab);
            string cond = line.Substring(tab + 1);
            if (!RANDOM.IsMatch(cond)) { continue; }
            if (!byName.ContainsKey(defName)) { byName[defName] = new Dictionary<string, List<int>>(); }
            if (!byName[defName].ContainsKey(cond)) { byName[defName][cond] = new List<int>(); }
            byName[defName][cond].Add(i + 1);
        }

        foreach (KeyValuePair<string, Dictionary<string, List<int>>> d in byName)
        {
            foreach (KeyValuePair<string, List<int>> r in d.Value)
            {
                if (r.Value.Count < 2) { continue; }
                foreach (int ln in r.Value)
                {
                    Add(name, ln, "warning",
                        d.Key + " の採用条件「" + Visible(r.Key) + "」は、同じ記述が " + r.Value.Count + " 回あるので1回しか評価されません。"
                        + "（乱数…）が全候補で同じ値になり、抽選になりません。");
                }
            }
        }
    }

    // 11 名前の重複
    static void CollectNames(string file, string[] lines,
                             Dictionary<string, Dictionary<string, List<string>>> names)
    {
        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i].TrimEnd('\r');
            if (line.Length == 0) { continue; }
            string kind = null, nm = null;
            if (line[0] == '＊') { kind = "トーク"; }
            else if (line[0] == '＠') { kind = "単語群"; }
            else if (line[0] == '＄') { kind = "変数"; }

            if (kind != null)
            {
                if (line[0] == '＄')
                {
                    Match m = ASSIGN.Match(line);
                    if (!m.Success) { continue; }
                    nm = m.Groups[1].Value.Trim();
                }
                else
                {
                    int tab = line.IndexOf('\t');
                    nm = (tab < 0) ? line.Substring(1) : line.Substring(1, tab - 1);
                    nm = nm.Trim();
                }
                if (nm.Length == 0) { continue; }
                if (!names.ContainsKey(nm)) { names[nm] = new Dictionary<string, List<string>>(); }
                if (!names[nm].ContainsKey(kind)) { names[nm][kind] = new List<string>(); }
                names[nm][kind].Add(file + ":" + (i + 1));
            }

            // （set,名前,…）。名前が静的なときだけ
            foreach (Match m in Regex.Matches(line, @"[（(]set[、､，,]([^（）(),、､，]+)[、､，,]"))
            {
                string sn = m.Groups[1].Value.Trim();
                if (sn.Length == 0) { continue; }
                if (!names.ContainsKey(sn)) { names[sn] = new Dictionary<string, List<string>>(); }
                if (!names[sn].ContainsKey("変数")) { names[sn]["変数"] = new List<string>(); }
                names[sn]["変数"].Add(file + ":" + (i + 1));
            }
        }
    }

    static void CheckDuplicateNames(Dictionary<string, Dictionary<string, List<string>>> names)
    {
        foreach (KeyValuePair<string, Dictionary<string, List<string>>> n in names)
        {
            if (n.Value.Count < 2) { continue; }
            List<string> kinds = new List<string>(n.Value.Keys);
            kinds.Sort(StringComparer.Ordinal);
            foreach (KeyValuePair<string, List<string>> k in n.Value)
            {
                foreach (string loc in k.Value)
                {
                    int colon = loc.LastIndexOf(':');
                    Add(loc.Substring(0, colon), int.Parse(loc.Substring(colon + 1)), "warning",
                        "「" + n.Key + "」が " + string.Join(" と ", kinds.ToArray())
                        + " の両方で使われています。片方が読めなくなりますが、存在確認では両方 1 を返します。");
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // 入口
    // -----------------------------------------------------------------------

    // Unicode 版（Mc2XX）は文字列を UTF-16 で持つ
    static bool IsUnicode(string dir)
    {
        return DllHas(dir, "satori_bootconf.txt");
    }

    // ShioriLint を受け付ける里々（Mc206-1 以降）は、イベント名を UTF-16 で持つ
    public static bool HasShioriLint(string dir)
    {
        return DllHas(dir, "ShioriLint");
    }

    static bool DllHas(string dir, string s)
    {
        Encoding latin1 = Encoding.GetEncoding(28591);
        return latin1.GetString(File.ReadAllBytes(Path.Combine(dir, "satori.dll")))
            .Contains(latin1.GetString(Encoding.Unicode.GetBytes(s)));
    }

    static bool IsValidUtf8(byte[] b)
    {
        try { new UTF8Encoding(false, true).GetString(b); return true; }
        catch (DecoderFallbackException) { return false; }
    }

    // 里々がこのファイルを読む文字コードで読む。読まないファイルは null
    static string ReadSatoriText(string path, bool unicode, bool fixedUtf8)
    {
        byte[] b = File.ReadAllBytes(path);
        bool bom = b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF;
        if (fixedUtf8 || (unicode && (bom || IsValidUtf8(b)))) { return new UTF8Encoding(false).GetString(b, bom ? 3 : 0, b.Length - (bom ? 3 : 0)); }
        return bom ? null : Encoding.GetEncoding(932).GetString(b);
    }

    // 1行の先頭「ファイル(行) : 」
    static readonly Regex LOCATION = new Regex(@"^(.+)\((\d+)\) : ");

    // satori は里々の lint の結果（ErrorDescription の各要素）。同じ形なので、そのまま一緒に並べる
    public static string[] Run(string dir, bool dicUtf8, string replacePath, bool repUtf8, string[] satori)
    {
        issues.Clear();
        ErrorCount = 0;
        bool unicode = IsUnicode(dir);

        List<string[]> rules = new List<string[]>();
        string repText = File.Exists(replacePath) ? ReadSatoriText(replacePath, unicode, repUtf8) : null;
        if (repText != null)
        {
            foreach (string line in repText.Replace("\r\n", "\n").Split('\n'))
            {
                if (line.Length == 0 || line[0] == '＃') { continue; }
                int tab = line.IndexOf('\t');
                if (tab > 0) { rules.Add(new string[] { line.Substring(0, tab), line.Substring(tab + 1) }); }
            }
        }

        string[] paths = Directory.GetFiles(dir, "dic*.txt", SearchOption.AllDirectories);
        Array.Sort(paths, StringComparer.Ordinal);

        List<string> output = new List<string>();
        if (paths.Length == 0)
        {
            output.Add("dic*.txt が見つかりません: " + dir);
            ErrorCount = 1;
            return output.ToArray();
        }

        Dictionary<string, Dictionary<string, List<string>>> names =
            new Dictionary<string, Dictionary<string, List<string>>>();

        // 1周目: 読み込みと、呼び先を辿るための定義の収集
        defs.Clear();
        List<string[]> loaded = new List<string[]>();
        foreach (string path in paths)
        {
            // 里々の lint と同じく、master からの相対パスを / で区切る
            string fname = path.Substring(dir.Length).TrimStart('\\', '/').Replace('\\', '/');
            string raw;
            try { raw = ReadSatoriText(path, unicode, dicUtf8); }
            catch (Exception ex) { output.Add("読み込み失敗: " + fname + " (" + ex.Message + ")"); continue; }
            if (raw == null) { output.Add("検査しない: " + fname + " (この satori.dll は BOM 付きのファイルを読めません)"); continue; }
            raw = raw.Replace("\r\n", "\n");

            string text = StripComments(MaskEscapes(raw));
            string[] lines = text.Split('\n');

            if (rules.Count > 0)
            {
                for (int i = 0; i < lines.Length; i++)
                {
                    foreach (string[] r in rules) { lines[i] = lines[i].Replace(r[0], r[1]); }
                }
                text = string.Join("\n", lines);
            }

            CollectDefs(lines);
            loaded.Add(new string[] { fname, text });
        }

        // 2周目: 検査
        foreach (string[] item in loaded)
        {
            string fname = item[0];
            string text = item[1];
            string[] lines = text.Split('\n');

            List<int> lineStarts = BuildLineStarts(text);

            List<Node> nodes = new List<Node>();
            List<int> unclosed = new List<int>();
            List<int> orphan = new List<int>();
            ScanParens(text, nodes, unclosed, orphan);

            CheckParens(fname, text, lines, lineStarts, unclosed, orphan);

            // 未閉じがあると括弧の範囲を取り違えるので、このファイルは打ち切る
            if (unclosed.Count > 0) { continue; }

            CheckSwallow(fname, text, lineStarts, nodes);
            CheckNodes(fname, text, lineStarts, nodes);
            CheckLines(fname, lines);
            CheckRandom(fname, lines);
            CollectNames(fname, lines, names);
        }

        CheckDuplicateNames(names);

        // ファイルと行の順に並べる。先頭が「ファイル(行) : 」でない行（件数を省略したという知らせなど）は最後。
        // 同じ位置は元の順（自前が先）を保つ
        issues.AddRange(satori);
        List<KeyValuePair<int, string>> order = new List<KeyValuePair<int, string>>();
        for (int k = 0; k < issues.Count; k++) { order.Add(new KeyValuePair<int, string>(k, issues[k])); }
        order.Sort(delegate(KeyValuePair<int, string> a, KeyValuePair<int, string> b)
        {
            Match ma = LOCATION.Match(a.Value), mb = LOCATION.Match(b.Value);
            if (ma.Success != mb.Success) { return ma.Success ? -1 : 1; }
            int c = 0;
            if (ma.Success)
            {
                c = string.CompareOrdinal(ma.Groups[1].Value, mb.Groups[1].Value);
                if (c == 0) { c = long.Parse(ma.Groups[2].Value).CompareTo(long.Parse(mb.Groups[2].Value)); }
            }
            return (c != 0) ? c : a.Key.CompareTo(b.Key);
        });
        foreach (KeyValuePair<int, string> e in order) { output.Add(e.Value); }
        return output.ToArray();
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

$dicUtf8 = $false
$repUtf8 = $false
$bootconf = Join-Path $MasterDir 'satori_bootconf.txt'
if (Test-Path $bootconf) {
    $conf = [IO.File]::ReadAllText($bootconf, [Text.Encoding]::ASCII)
    if ($conf -match 'is_utf8_dic\s*,\s*true'     -or $conf -match 'is_utf8_all\s*,\s*true') { $dicUtf8 = $true }
    if ($conf -match 'is_utf8_replace\s*,\s*true' -or $conf -match 'is_utf8_all\s*,\s*true') { $repUtf8 = $true }
}

# 里々の lint。一時フォルダのコピーで、テスターから送る。
# テスターは別のプロセスで動かす。同じプロセスだと satori.dll が読み込まれたまま残り、一時フォルダを消せない
# ShioriLint を持たない里々は読み込まない
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('satori_lint_' + [Guid]::NewGuid().ToString('N'))
$copy = Join-Path $tmp 'master'
$res = ''
$hasLint = [SatoriLint]::HasShioriLint($MasterDir)
if ($hasLint) {
    try {
        New-Item -ItemType Directory -Force $copy | Out-Null
        foreach ($n in 'satori.dll', 'satori_bootconf.txt', 'satori_conf.txt', 'replace.txt', 'replace_after.txt') {
            $src = Join-Path $MasterDir $n
            if (Test-Path $src) { Copy-Item $src $copy }
        }
        $full = (Resolve-Path $MasterDir).Path.TrimEnd('\')
        Get-ChildItem $full -Filter 'dic*.txt' -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($full.Length).TrimStart('\')
            if ($rel -like 'saori\*') { return }
            $dest = Join-Path $copy $rel
            New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
            Copy-Item $_.FullName $dest
        }
        $seq = Join-Path $tmp 'seq.txt'
        [IO.File]::WriteAllText($seq, "[ShioriLint]`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $res = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'satori_runner.ps1') $seq $copy $tmp) -join "`n"
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# 里々の lint が無いときと、結果を取れなかったときは、そのことを先頭に出す。出さないと、誤りが無いと読める
$levels = @(); $descs = @()
if (-not $hasLint) {
    Write-Output 'この satori.dll は古い版のため、公式の lint（ShioriLint）がありません。存在しない飛び先や引数の個数の誤りは、テスターで見てください。'
}
else {
    $section = $res.Substring([Math]::Max(0, $res.IndexOf('========== ShioriLint ==========')))
    if ($section -match '(?m)^SHIORI/3\.0 200') {
        if ($section -match '(?m)^ErrorLevel: (.*)$')       { $levels = $Matches[1] -split [char]1 }
        if ($section -match '(?m)^ErrorDescription: (.*)$') { $descs  = $Matches[1] -split [char]1 }
    }
    else {
        Write-Output '里々の lint の結果を取得できませんでした。テスターの出力:'
        $res -split "`n" | Select-Object -First 20 | ForEach-Object { Write-Output "  $_" }
    }
}

[SatoriLint]::Run($MasterDir, $dicUtf8, (Join-Path $MasterDir 'replace.txt'), $repUtf8, [string[]]$descs) | ForEach-Object { Write-Output $_ }
if ([SatoriLint]::ErrorCount -gt 0 -or $levels -contains 'error') { exit 1 } else { exit 0 }

