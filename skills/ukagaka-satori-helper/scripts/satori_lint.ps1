# satori_lint.ps1
#
# 里々もテスターも何も言わない誤りを検出する。
#
#   powershell -ExecutionPolicy Bypass -File satori_lint.ps1 <ghost/master>
#
# 使い方
#   辞書を書いた後、テスターでエラーが無くなってから通す。
#   里々がエラーを出している状態では通さない。
#   本番の ghost/master を渡す。読むだけで、書き換えない。
#
#   **結果を利用者に見せない。**修正方針を決めるためだけに使う。
#   利用者が意図して書いたかどうかを判別できないので、
#   検出したものをそのまま「誤り」として提示しない。
#   見るのは自分が書いた箇所・修正を依頼された箇所だけ。
#
# 何を検出するか ── 里々もテスターも何も言わないもの
#   [error] if / iflist の枝に set や call がある（両方の枝が実行される）
#   [error] 遅延する関数の引数がカッコで区切られている（if と同じ動作になる）
#   [warn ] 採用条件がタブで区切られていない（条件が本文になり、常に採用される）
#   [warn ] 条件式に数値にならない文字列を書いている（0 とみなされ常に偽）
#   [warn ] 同名定義の採用条件に、同一の（乱数…）が2回以上ある（1回しか評価されない）
#   [warn ] 括弧の中の字下げがタブでない（空白が引数に残る）
#   [error] 行頭の ＄ ＞ ＿ の直後が空白（空白込みの名前で登録される）
#   [error] ＝ / = の手前が空白（代入されない）
#   [warn ] タブ区切りの代入に計算されない演算子がある（数式が文字列として格納される）
#   [error] タブ代入の自己参照に計算されない演算子がある（数式が文字列として際限なく伸びる）
#   [error] システム変数（A○ R○ C○ S○）に代入している（引数・カウンタが壊れる）
#   [warn ] 変数・単語群・トークで同じ名前を使っている（片方が読めなくなる）
#   [error] 開きカッコが閉じていない（ファイル全体が無効になる）
#   [warn ] 閉じカッコが過剰（里々は動くが、入れ子の書き間違いの兆候）
#
# 何を検出しないか ── 里々が場所まで報告する。テスターを通せば分かる
#   引数個数が合わない        「引数の個数が正しくありません。」を出力に混ぜる
#   ＄行に区切りが無い        「※　＄による変数代入文には…※」をバルーンに出す
#   行頭に空白がある ＄ ＞ ＿  その行をそのまま本文として表示する
#   未定義の参照              括弧ごと画面に出す
#   関数名に空白              同上
#   == による比較             && || ! なら「' 式が計算不能です。」を出力に混ぜる
#
# replace.txt を適用してから検査する
#   里々が実際に見るのは置換後の文字列なので、同じものを検査する。
#   辞書と replace.txt は別の設定で文字コードが決まる。
#   辞書は is_utf8_dic、replace.txt は is_utf8_replace。is_utf8_all は両方に効く。
#   行ごとに置換するので行番号は保たれる。
#   出力するファイル名と行番号は本番の辞書に対応する。修正するのは本番。
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
里々もテスターも何も言わない誤りを検出する。

  satori_lint.ps1 <ghost/master>

    結果は利用者に見せない。修正方針を決めるためだけに使う。
'@

if (-not $MasterDir) { Write-Output $usage; exit 1 }
if (-not (Test-Path $MasterDir)) { Write-Output "見つかりません: $MasterDir"; exit 1 }

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
    static readonly string[] LAZY = { "when", "whenlist", "unless", "for", "times", "while" };

    // 遅延しない関数。枝に副作用があると両方実行される
    static readonly string[] EAGER = { "if", "iflist" };

    // 副作用のある呼び出し
    static readonly string[] SIDE_EFFECT = { "set", "call" };

    // システム変数。代入すると引数・カウンタが壊れる
    static readonly Regex SYSTEM_VAR = new Regex(@"^[ARCSＡＲＣＳ][0-9０-９]+$");

    // ＄への代入の区切り
    static readonly Regex ASSIGN = new Regex(@"^＄([^\t＝=]*)([\t＝=])(.*)$");

    // 計算式とみなす演算子
    static readonly char[] OPERATORS = { '+', '-', '*', '/', '%', '＋', '－', '×', '÷', '％' };

    // 比較演算子
    static readonly Regex COMPARE = new Regex(@"==|!=|>=|<=|＝＝|！＝|＞＝|＜＝|>|<|＞|＜");

    // 採用条件の中の乱数
    static readonly Regex RANDOM = new Regex(@"[（(]乱数[^（）()]*[）)]");

    // 先頭から数値として読めるか（strtol 相当）
    static readonly Regex LEADING_NUM = new Regex(@"^\s*[+-]?[0-9０-９]");

    // -----------------------------------------------------------------------

    class Issue
    {
        public string File, Level, Kind, Message, Snippet;
        public int Line;
    }

    class Node { public int Start, End; }

    static List<Issue> issues = new List<Issue>();
    public static int ErrorCount = 0;

    static void Add(string file, int line, string level, string kind, string msg, string snippet)
    {
        Issue i = new Issue();
        i.File = file; i.Line = line; i.Level = level;
        i.Kind = kind; i.Message = msg; i.Snippet = snippet;
        issues.Add(i);
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

    static string Visible(string s)
    {
        return s.Replace("\t", "⇥").Replace("\r", "").Replace("\n", "⏎");
    }

    static string Excerpt(string text, int pos)
    {
        int end = text.IndexOf('\n', pos);
        if (end < 0) { end = text.Length; }
        int len = Math.Min(end - pos, 70);
        return Visible(text.Substring(pos, len));
    }

    static string LineText(string[] lines, int line)
    {
        return (line - 1 < lines.Length) ? Visible(lines[line - 1]) : "";
    }

    // 括弧の対応。φ（ φ） は数えない
    static void ScanParens(string text, List<Node> nodes, List<int> unclosed, List<int> orphan)
    {
        List<int> stack = new List<int>();
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (c != '（' && c != '）') { continue; }
            if (i > 0 && text[i - 1] == 'φ') { continue; }
            if (c == '（') { stack.Add(i); }
            else
            {
                if (stack.Count == 0) { orphan.Add(i); }
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

    // 括弧の外（地の文）に演算子があるか
    static bool HasOperatorInText(string val)
    {
        int depth = 0;
        foreach (char c in val)
        {
            if (c == '（' || c == '(') depth++;
            else if (c == '）' || c == ')') depth--;
            else if (depth <= 0 && Array.IndexOf(OPERATORS, c) >= 0) return true;
        }
        return false;
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
            Add(name, LineOf(lineStarts, pos), "error", "カッコ未閉じ",
                "開きカッコ「（」に対応する「）」がありません。このファイルの定義はすべて無効になります。",
                Excerpt(text, pos));
        }
        foreach (int pos in orphan)
        {
            Add(name, LineOf(lineStarts, pos), "warn", "カッコ過剰",
                "対応する「（」のない閉じカッコ「）」があります。里々は影響を受けませんが、入れ子の書き間違いの疑いがあります。",
                Excerpt(text, Math.Max(0, pos - 30)));
        }
    }

    // 1 ifの副作用 / 2 カッコ区切り / 6 字下げ
    static void CheckNodes(string name, string text, List<int> lineStarts, List<Node> nodes)
    {
        foreach (Node node in nodes)
        {
            string body = text.Substring(node.Start + 1, node.End - node.Start - 1);
            string fn = FuncName(body);
            int line = LineOf(lineStarts, node.Start);

            // 1 ifの副作用
            if (In(EAGER, fn))
            {
                foreach (string se in SIDE_EFFECT)
                {
                    if (body.IndexOf("（" + se) >= 0)
                    {
                        Add(name, line, "error", "ifの副作用",
                            fn + " の枝に " + se + " があります。両方の枝が実行されるので when / whenlist を使ってください。",
                            Excerpt(text, node.Start));
                        break;
                    }
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
                    Add(name, line, "error", "カッコ区切り",
                        fn + " の引数がカッコで区切られています。区切りが展開後に決まるため遅延が効かず、if と同じ動作になります。",
                        Excerpt(text, node.Start));
                }
            }

            // 6 字下げ（括弧の中で、改行の直後にタブ以外の空白）
            for (int i = 1; i < body.Length; i++)
            {
                if (body[i - 1] != '\n') { continue; }
                if (body[i] == ' ' || body[i] == '　')
                {
                    Add(name, LineOf(lineStarts, node.Start + 1 + i), "warn", "字下げ",
                        "括弧の中の字下げにタブ以外の空白が使われています。里々が読み飛ばすのは行頭タブだけなので、空白が引数に残ります。",
                        Excerpt(text, node.Start + 1 + i));
                    break;
                }
            }
        }
    }

    // 3 条件の区切り / 4 文字列条件 / 7 記号の直後 / 8 ＝の手前 / 9 タブ代入の式 / 10 システム変数
    static void CheckLines(string name, string[] lines)
    {
        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i].TrimEnd('\r');
            if (line.Length == 0) { continue; }
            char head = line[0];
            int ln = i + 1;

            // 7 記号の直後が空白
            if (head == '＄' || head == '＞' || head == '＿')
            {
                if (line.Length > 1 && IsSpace(line[1]))
                {
                    Add(name, ln, "error", "記号の直後",
                        head + " の直後が空白です。空白込みの名前として登録されるので、参照できません。",
                        Visible(line));
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
                        Add(name, ln, "error", "＝の手前",
                            "＝ の手前に空白があります。里々は代入しません。",
                            Visible(line));
                    }

                    // 10 システム変数
                    string bare = vname.TrimEnd(' ', '　', '\t');
                    if (SYSTEM_VAR.IsMatch(bare))
                    {
                        Add(name, ln, "error", "システム変数",
                            bare + " はシステムが使う名前です。引数やループカウンタを壊します。",
                            Visible(line));
                    }

                    // 9 タブ区切りの代入に式
                    if (sep == '\t' && HasOperatorInText(val))
                    {
                        string self = "（" + vname + "）";
                        if (val.Contains(self) || val.Contains("(" + vname + ")"))
                        {
                            Add(name, ln, "error", "自己参照の演算",
                                "タブ代入の自己参照に計算されない演算子があります。数式が文字列として際限なく伸びます。＝ を使ってください。",
                                Visible(line));
                        }
                        else
                        {
                            Add(name, ln, "warn", "タブ代入の演算",
                                "タブ区切りの代入に計算されない演算子があります。数式が文字列として格納されます。＝ か calc を使ってください。",
                                Visible(line));
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
                        Add(name, ln, "warn", "条件の区切り",
                            "採用条件がタブで区切られていません。条件が名前の一部として扱われます。",
                            Visible(line));
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
                        Add(name, ln, "warn", "文字列条件",
                            "採用条件が数値になりません。0 とみなされ、常に偽になります。",
                            Visible(line));
                    }
                }
            }
        }
    }

    // 5 乱数の共有
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
            foreach (Match m in RANDOM.Matches(cond))
            {
                if (!byName.ContainsKey(defName)) { byName[defName] = new Dictionary<string, List<int>>(); }
                if (!byName[defName].ContainsKey(m.Value)) { byName[defName][m.Value] = new List<int>(); }
                byName[defName][m.Value].Add(i + 1);
            }
        }

        foreach (KeyValuePair<string, Dictionary<string, List<int>>> d in byName)
        {
            foreach (KeyValuePair<string, List<int>> r in d.Value)
            {
                if (r.Value.Count < 2) { continue; }
                foreach (int ln in r.Value)
                {
                    Add(name, ln, "warn", "乱数の共有",
                        d.Key + " の採用条件にある " + r.Key + " は、同じ記述なので1回しか評価されません。"
                        + "全候補で同じ値になり、抽選になりません。",
                        LineText(lines, ln));
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
                    Add(loc.Substring(0, colon), int.Parse(loc.Substring(colon + 1)), "warn", "名前の重複",
                        "「" + n.Key + "」が " + string.Join(" と ", kinds.ToArray())
                        + " の両方で使われています。片方が読めなくなりますが、存在確認では両方 1 を返します。",
                        "");
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // 入口
    // -----------------------------------------------------------------------

    public static string[] Run(string dir, string encName, string replacePath, string encRepName)
    {
        issues.Clear();
        ErrorCount = 0;
        Encoding enc = Encoding.GetEncoding(encName);

        List<string[]> rules = new List<string[]>();
        if (File.Exists(replacePath))
        {
            Encoding encR = Encoding.GetEncoding(encRepName);
            foreach (string line in File.ReadAllLines(replacePath, encR))
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

        foreach (string path in paths)
        {
            string fname = path.Substring(dir.Length).TrimStart('\\', '/');
            string raw;
            try { raw = File.ReadAllText(path, enc).Replace("\r\n", "\n"); }
            catch (Exception ex) { output.Add("読み込み失敗: " + fname + " (" + ex.Message + ")"); continue; }

            string text = StripComments(raw);
            string[] lines = text.Split('\n');

            if (rules.Count > 0)
            {
                for (int i = 0; i < lines.Length; i++)
                {
                    foreach (string[] r in rules) { lines[i] = lines[i].Replace(r[0], r[1]); }
                }
                text = string.Join("\n", lines);
            }

            List<int> lineStarts = BuildLineStarts(text);

            List<Node> nodes = new List<Node>();
            List<int> unclosed = new List<int>();
            List<int> orphan = new List<int>();
            ScanParens(text, nodes, unclosed, orphan);

            CheckParens(fname, text, lines, lineStarts, unclosed, orphan);

            // 未閉じがあると括弧の範囲を取り違えるので、このファイルは打ち切る
            if (unclosed.Count > 0)
            {
                Add(fname, LineOf(lineStarts, unclosed[0]), "error", "検査の打ち切り",
                    "カッコが閉じていないため、このファイルの他の検査を行いませんでした。", "");
                continue;
            }

            CheckNodes(fname, text, lineStarts, nodes);
            CheckLines(fname, lines);
            CheckRandom(fname, lines);
            CollectNames(fname, lines, names);
        }

        CheckDuplicateNames(names);

        issues.Sort(delegate(Issue a, Issue b)
        {
            int c = string.CompareOrdinal(a.File, b.File);
            if (c != 0) { return c; }
            return a.Line.CompareTo(b.Line);
        });

        int warnCount = 0;
        foreach (Issue i in issues)
        {
            if (i.Level == "error") { ErrorCount++; } else { warnCount++; }
            output.Add(string.Format("{0}:{1}: [{2}] {3}: {4}", i.File, i.Line, i.Level, i.Kind, i.Message));
            if (i.Snippet.Length > 0) { output.Add("    > " + i.Snippet); }
        }

        output.Add("");
        output.Add(string.Format("error {0} 件 / warn {1} 件", ErrorCount, warnCount));
        return output.ToArray();
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

$encDic = 'shift_jis'
$encRep = 'shift_jis'
$bootconf = Join-Path $MasterDir 'satori_bootconf.txt'
if (Test-Path $bootconf) {
    $conf = [IO.File]::ReadAllText($bootconf, [Text.Encoding]::ASCII)
    if ($conf -match 'is_utf8_dic\s*,\s*true'     -or $conf -match 'is_utf8_all\s*,\s*true') { $encDic = 'utf-8' }
    if ($conf -match 'is_utf8_replace\s*,\s*true' -or $conf -match 'is_utf8_all\s*,\s*true') { $encRep = 'utf-8' }
}

[SatoriLint]::Run($MasterDir, $encDic, (Join-Path $MasterDir 'replace.txt'), $encRep) | ForEach-Object { Write-Output $_ }
if ([SatoriLint]::ErrorCount -gt 0) { exit 1 } else { exit 0 }

