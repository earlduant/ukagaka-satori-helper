# satori_dic.ps1
#
# 里々の辞書（Shift_JIS 等）を安全に読み書きするためのツール。
# AI が直接ファイルを編集して文字化けしたり構造を壊したりするのを防ぐ。
#
#   powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 <コマンド> <引数...>
#
# コマンド
#   list <master> <作業フォルダ>
#       対象ファイルを列挙。結果が「Shift_JISが混じります」なら、以後の読み書きはすべて本ツールを通す。
#       「UTF-8です」なら直接編集してよい。
#   find <master> <作業フォルダ> <語>
#       対象ファイルから指定した文字列を部分一致で検索する（大小文字・全角半角を区別）。
#   read <ファイル> <作業フォルダ> <開始行> <終了行>
#       指定範囲の行を読む。終了行が総行数を超えたら末尾まで返す。行末の空白を警告する。
#   write <ファイル> <作業フォルダ> <内容ファイル> <開始行> <終了行>
#       指定範囲を内容ファイルの中身で置き換える。終了行が総行数を超えたら拒否。
#   insert <ファイル> <作業フォルダ> <内容ファイル> <行番号>
#       指定した行の「前」に内容ファイルを挿入する。末尾追加は <総行数+1> を指定。
#   create <ファイル> <作業フォルダ> <内容ファイル>
#       新規作成。satori_bootconf.txt の設定に従った文字コードで保存される（BOMなし）。
#
# 内容ファイルについて (write / insert / create)
#   書き込む中身を UTF-8 で書いたファイル。絶対パスで渡すこと。
#   一時領域のフォルダに作る。同じファイルを使い回してよい（追記せず全部書き直す）。
#   末尾の改行の有無は結果に影響しない。
#
# 制御文字の扱い
#   AI が扱えない制御文字（0x01など）は、read / find では ^'0xNN^' として見える。
#   write / insert / create 時にそのまま ^'0xNN^' を含めれば、元の制御文字に戻る。

param(
    [Parameter(Position=0)] [string] $Command,
    [Parameter(Position=1)] [string] $Target,
    [Parameter(Position=2)] [string] $WorkDir,
    [Parameter(Position=3)] [AllowEmptyString()] [string] $Arg1,
    [Parameter(Position=4)] [AllowEmptyString()] [string] $Arg2,
    [Parameter(Position=5)] [AllowEmptyString()] [string] $Arg3
)

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

if (-not $Command -or -not $Target -or -not $WorkDir) {
    Write-Output "引数が足りません"
    exit 1
}

$code = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Text.RegularExpressions;

public class SatoriDic
{
    public static int ExitCode = 0;

    class FileData {
        public byte[] bom;
        public string[] lines;
        public bool hasTrailingNewline;
        public Encoding enc;
        public string error;
    }

    class ContentData {
        public string[] lines;
        public string error;
        public bool emptyTrailing;
    }

    class BootConf {
        public bool dic;
        public bool replace;
        public bool all;
        public bool AllUtf8 { get { return all || (dic && replace); } }
    }

    static string FindMaster(string path, out string error) {
        error = null;
        string norm = path.Replace('/', '\\');
        if (!norm.EndsWith("\\")) norm += "\\";
        int idx = norm.IndexOf("\\ghost\\master\\", StringComparison.OrdinalIgnoreCase);
        if (idx < 0) {
            error = "拒否: ghost\\master の下にあるファイルを指定してください";
            return null;
        }
        int lastIdx = idx;
        while(true) {
            int next = norm.IndexOf("\\ghost\\master\\", lastIdx + 1, StringComparison.OrdinalIgnoreCase);
            if (next < 0) break;
            lastIdx = next;
        }
        string master = norm.Substring(0, lastIdx + 14);
        if (!File.Exists(Path.Combine(master, "satori.dll"))) {
            error = "拒否: satori.dll がありません。ghost\\master ではないようです";
            return null;
        }
        return master;
    }

    static BootConf ReadBootConf(string master) {
        BootConf c = new BootConf();
        string p = Path.Combine(master, "satori_bootconf.txt");
        if (File.Exists(p)) {
            string t = File.ReadAllText(p, Encoding.ASCII);
            if (Regex.IsMatch(t, @"is_utf8_dic\s*,\s*true", RegexOptions.IgnoreCase)) c.dic = true;
            if (Regex.IsMatch(t, @"is_utf8_replace\s*,\s*true", RegexOptions.IgnoreCase)) c.replace = true;
            if (Regex.IsMatch(t, @"is_utf8_all\s*,\s*true", RegexOptions.IgnoreCase)) c.all = true;
        }
        return c;
    }

    static Encoding GetEncoding(BootConf c, string file) {
        string name = Path.GetFileName(file).ToLower();
        bool u = false;
        if ((name.StartsWith("dic") && name.EndsWith(".txt")) || name == "satori_conf.txt") {
            u = c.dic || c.all;
        } else if (name == "replace.txt" || name == "replace_after.txt") {
            u = c.replace || c.all;
        }
        return u ? new UTF8Encoding(false) : Encoding.GetEncoding(932);
    }

    static bool IsSatoriFile(string file) {
        string name = Path.GetFileName(file).ToLower();
        if (name.StartsWith("dic") && name.EndsWith(".txt")) return true;
        if (name == "replace.txt" || name == "replace_after.txt" || name == "satori_conf.txt") return true;
        return false;
    }

    static string EscapeCtrl(string s) {
        StringBuilder sb = new StringBuilder();
        foreach(char c in s) {
            if ((c >= 0x00 && c <= 0x08) || c == 0x0B || c == 0x0C || (c >= 0x0E && c <= 0x1F)) {
                sb.AppendFormat("^'0x{0:X2}^'", (int)c);
            } else {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }

    static string UnescapeCtrl(string s) {
        return Regex.Replace(s, @"\^'0x([0-9a-fA-F]{2})\^'", m => {
            int v = Convert.ToInt32(m.Groups[1].Value, 16);
            if ((v >= 0x00 && v <= 0x08) || v == 0x0B || v == 0x0C || (v >= 0x0E && v <= 0x1F)) {
                return ((char)v).ToString();
            }
            return m.Value;
        });
    }

    static string GetTrailingSpaceWarning(string line) {
        if (line.Length == 0) return null;
        int tail = line.Length - 1;
        List<string> blocks = new List<string>();
        while (tail >= 0) {
            char c = line[tail];
            if (c == ' ' || c == '　' || c == '\t') {
                int start = tail;
                while(start >= 0 && line[start] == c) start--;
                int count = tail - start;
                string name = (c == ' ') ? "半角" : (c == '　' ? "全角" : "タブ");
                blocks.Add(name + count);
                tail = start;
            } else {
                break;
            }
        }
        if (blocks.Count == 0) return null;
        blocks.Reverse();
        return string.Join(" ", blocks);
    }

    static FileData ReadFile(string path, Encoding enc) {
        FileData fd = new FileData();
        fd.enc = enc;
        if (!File.Exists(path)) { fd.error = "拒否: ファイルがありません"; return fd; }
        byte[] bytes = File.ReadAllBytes(path);
        int offset = 0;
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
            fd.bom = new byte[] { 0xEF, 0xBB, 0xBF };
            offset = 3;
        } else {
            fd.bom = new byte[0];
        }
        string text = enc.GetString(bytes, offset, bytes.Length - offset);
        byte[] reencoded = enc.GetBytes(text);
        if (reencoded.Length != bytes.Length - offset) {
            fd.error = "拒否: 文字コードが satori_bootconf.txt の設定と合いません";
            return fd;
        }
        for (int i=0; i<reencoded.Length; i++) {
            if (reencoded[i] != bytes[offset + i]) {
                fd.error = "拒否: 文字コードが satori_bootconf.txt の設定と合いません";
                return fd;
            }
        }
        
        string tmp = text.Replace("\r\n", "");
        if (tmp.IndexOf('\n') >= 0 || tmp.IndexOf('\r') >= 0) {
            fd.error = "拒否: 改行コードが CRLF ではありません";
            return fd;
        }

        if (text.Length == 0) {
            fd.lines = new string[0];
            fd.hasTrailingNewline = false;
        } else {
            fd.hasTrailingNewline = text.EndsWith("\r\n");
            string t2 = fd.hasTrailingNewline ? text.Substring(0, text.Length - 2) : text;
            fd.lines = t2.Split(new string[] { "\r\n" }, StringSplitOptions.None);
        }
        return fd;
    }

    static string CheckCP932(string[] lines) {
        Encoding sjis = Encoding.GetEncoding(932, new EncoderExceptionFallback(), new DecoderExceptionFallback());
        for(int i=0; i<lines.Length; i++) {
            string line = lines[i];
            for (int j=0; j<line.Length; j++) {
                string ch;
                if (char.IsHighSurrogate(line[j]) && j + 1 < line.Length && char.IsLowSurrogate(line[j+1])) {
                    ch = line.Substring(j, 2);
                    j++;
                } else {
                    ch = line.Substring(j, 1);
                }
                try {
                    sjis.GetBytes(ch);
                } catch {
                    int cp = char.ConvertToUtf32(ch, 0);
                    return string.Format("拒否: CP932 に変換できない文字があります\n  内容ファイル {0}行目  {1} (U+{2:X4})", i + 1, ch, cp);
                }
            }
        }
        return null;
    }

    static ContentData ReadContent(string path) {
        ContentData cd = new ContentData();
        if (!File.Exists(path)) { cd.error = "拒否: 内容ファイルがありません"; return cd; }
        byte[] bytes = File.ReadAllBytes(path);
        int offset = 0;
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) offset = 3;
        Encoding utf8 = new UTF8Encoding(false, true);
        string text;
        try {
            text = utf8.GetString(bytes, offset, bytes.Length - offset);
        } catch {
            cd.error = "拒否: 内容ファイルが UTF-8 ではありません"; return cd;
        }
        text = UnescapeCtrl(text);
        text = text.Replace("\r\n", "\n").Replace("\n", "\r\n");
        if (text.Length == 0) {
            cd.lines = new string[0];
            cd.emptyTrailing = false;
        } else {
            bool hasnl = text.EndsWith("\r\n");
            string t2 = hasnl ? text.Substring(0, text.Length - 2) : text;
            cd.lines = t2.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            cd.emptyTrailing = hasnl && (cd.lines.Length > 0 && cd.lines[cd.lines.Length - 1] == "");
            if (!hasnl && cd.lines.Length > 0 && cd.lines[cd.lines.Length - 1] == "") cd.emptyTrailing = true;
        }
        return cd;
    }

    static void RunList(string target, List<string> outLines) {
        string err;
        string master = FindMaster(target, out err);
        if (master == null) { outLines.Add(err); ExitCode = 1; return; }
        BootConf conf = ReadBootConf(master);

        string[] allFiles = Directory.GetFiles(master, "*", SearchOption.AllDirectories);
        List<string> valid = new List<string>();
        List<string> broken = new List<string>();

        foreach(string f in allFiles) {
            if (!IsSatoriFile(f)) continue;
            Encoding enc = GetEncoding(conf, f);
            FileData fd = ReadFile(f, enc);
            if (fd.error != null) {
                broken.Add(f + "|" + fd.error.Replace("拒否: ", "").Replace(" satori_bootconf.txt の", ""));
            } else {
                valid.Add(f + "|" + (enc is UTF8Encoding ? "UTF-8" : "Shift_JIS") + "|" + fd.lines.Length);
            }
        }

        if (valid.Count == 0 && broken.Count == 0) {
            outLines.Add("対象のファイルがありません");
            return;
        }

        if (conf.AllUtf8) {
            outLines.Add("このゴーストは UTF-8 です。直接編集しても壊れません。");
            outLines.Add("ただし行末の空白と制御文字は、標準のツールでは見えません。");
        } else {
            outLines.Add("Shift_JIS が混じります。satori_dic.ps1 を通してください。直接編集すると壊れます。");
        }
        outLines.Add("");

        foreach(string v in valid) outLines.Add(v);

        if (broken.Count > 0) {
            outLines.Add("");
            outLines.Add("扱えないファイル:");
            foreach(string b in broken) outLines.Add("  " + b);
        }
    }

    static void RunFind(string target, string word, List<string> outLines) {
        if (string.IsNullOrEmpty(word)) { outLines.Add("拒否: 検索する語を指定してください"); ExitCode = 1; return; }
        string err;
        string master = FindMaster(target, out err);
        if (master == null) { outLines.Add(err); ExitCode = 1; return; }
        BootConf conf = ReadBootConf(master);

        string[] allFiles = Directory.GetFiles(master, "*", SearchOption.AllDirectories);
        List<string> broken = new List<string>();
        int count = 0;

        foreach(string f in allFiles) {
            if (!IsSatoriFile(f)) continue;
            Encoding enc = GetEncoding(conf, f);
            FileData fd = ReadFile(f, enc);
            if (fd.error != null) {
                broken.Add(f + "|" + fd.error.Replace("拒否: ", "").Replace(" satori_bootconf.txt の", ""));
                continue;
            }
            for (int i=0; i<fd.lines.Length; i++) {
                if (fd.lines[i].Contains(word)) {
                    outLines.Add(f + "|" + (i + 1) + "|" + EscapeCtrl(fd.lines[i]));
                    count++;
                }
            }
        }
        outLines.Add(count + "件");
        if (broken.Count > 0) {
            outLines.Add("");
            outLines.Add("扱えないファイル:");
            foreach(string b in broken) outLines.Add("  " + b);
        }
    }

    static void RunRead(string target, string arg1, string arg2, List<string> outLines) {
        string err;
        string master = FindMaster(target, out err);
        if (master == null) { outLines.Add(err); ExitCode = 1; return; }
        BootConf conf = ReadBootConf(master);
        Encoding enc = GetEncoding(conf, target);
        FileData fd = ReadFile(target, enc);
        if (fd.error != null) { outLines.Add(fd.error); ExitCode = 1; return; }
        
        int start, end;
        if (!int.TryParse(arg1, out start) || start <= 0) { outLines.Add("拒否: 行番号は 1 以上です"); ExitCode = 1; return; }
        if (!int.TryParse(arg2, out end)) { outLines.Add("拒否: 終了行が不正です"); ExitCode = 1; return; }
        if (start > end) { outLines.Add("拒否: 開始行が終了行より後です"); ExitCode = 1; return; }
        
        int total = fd.lines.Length;
        if (total == 0) { outLines.Add("拒否: このファイルは 0行です"); ExitCode = 1; return; }
        if (start > total) { outLines.Add(string.Format("拒否: 開始行がファイルの行数を超えています。このファイルは {0}行です", total)); ExitCode = 1; return; }
        
        int actualEnd = end > total ? total : end;
        
        outLines.Add(target + "|" + (enc is UTF8Encoding ? "UTF-8" : "Shift_JIS") + "|" + total + "|" + start + "-" + actualEnd);
        outLines.Add("");
        
        List<string> warnings = new List<string>();
        for (int i = start - 1; i < actualEnd; i++) {
            outLines.Add((i + 1) + "|" + EscapeCtrl(fd.lines[i]));
            string w = GetTrailingSpaceWarning(fd.lines[i]);
            if (w != null) warnings.Add((i + 1) + "行目  " + w);
        }
        if (warnings.Count > 0) {
            outLines.Add("");
            outLines.Add("行末に空白:");
            foreach(string w in warnings) outLines.Add("  " + w);
        }
    }

    static void RunWrite(string target, string cFile, string arg1, string arg2, List<string> outLines) {
        string err;
        string master = FindMaster(target, out err);
        if (master == null) { outLines.Add(err); ExitCode = 1; return; }
        BootConf conf = ReadBootConf(master);
        Encoding enc = GetEncoding(conf, target);
        FileData fd = ReadFile(target, enc);
        if (fd.error != null) { outLines.Add(fd.error); ExitCode = 1; return; }
        
        int start, end;
        if (!int.TryParse(arg1, out start) || start <= 0) { outLines.Add("拒否: 行番号は 1 以上です"); ExitCode = 1; return; }
        if (!int.TryParse(arg2, out end)) { outLines.Add("拒否: 終了行が不正です"); ExitCode = 1; return; }
        if (start > end) { outLines.Add("拒否: 開始行が終了行より後です"); ExitCode = 1; return; }
        
        int total = fd.lines.Length;
        if (total == 0) { outLines.Add("拒否: このファイルは 0行です"); ExitCode = 1; return; }
        if (start > total) { outLines.Add(string.Format("拒否: 開始行がファイルの行数を超えています。このファイルは {0}行です", total)); ExitCode = 1; return; }
        if (end > total) { outLines.Add(string.Format("拒否: 終了行がファイルの行数を超えています。このファイルは {0}行です", total)); ExitCode = 1; return; }
        
        ContentData cd = ReadContent(cFile);
        if (cd.error != null) { outLines.Add(cd.error); ExitCode = 1; return; }
        
        if (!(enc is UTF8Encoding)) {
            string cpErr = CheckCP932(cd.lines);
            if (cpErr != null) { outLines.Add(cpErr); ExitCode = 1; return; }
        }

        List<string> newLines = new List<string>();
        for (int i=0; i<start-1; i++) newLines.Add(fd.lines[i]);
        for (int i=0; i<cd.lines.Length; i++) newLines.Add(cd.lines[i]);
        for (int i=end; i<total; i++) newLines.Add(fd.lines[i]);
        
        bool hasnl = fd.hasTrailingNewline;

        string result = string.Join("\r\n", newLines.ToArray());
        if (hasnl) result += "\r\n";
        
        byte[] finalBytes = enc.GetBytes(result);
        using (FileStream fs = new FileStream(target, FileMode.Create, FileAccess.Write)) {
            if (fd.bom.Length > 0) fs.Write(fd.bom, 0, fd.bom.Length);
            fs.Write(finalBytes, 0, finalBytes.Length);
        }

        int newTotal = ReadFile(target, enc).lines.Length;
        
        outLines.Add(target);
        if (cd.lines.Length == 0) {
            outLines.Add(string.Format("  差し替え  {0}-{1}行 → 削除", start, end));
        } else {
            outLines.Add(string.Format("  差し替え  {0}-{1}行 → {2}-{3}行", start, end, start, start + cd.lines.Length - 1));
        }
        outLines.Add(string.Format("  ファイル  {0}行 → {1}行", total, newTotal));
    }

    static void RunInsert(string target, string cFile, string arg1, List<string> outLines) {
        string err;
        string master = FindMaster(target, out err);
        if (master == null) { outLines.Add(err); ExitCode = 1; return; }
        BootConf conf = ReadBootConf(master);
        Encoding enc = GetEncoding(conf, target);
        FileData fd = ReadFile(target, enc);
        if (fd.error != null) { outLines.Add(fd.error); ExitCode = 1; return; }
        
        int line;
        if (!int.TryParse(arg1, out line) || line <= 0) { outLines.Add("拒否: 行番号は 1 以上です"); ExitCode = 1; return; }
        
        int total = fd.lines.Length;
        if (line > total + 1) { outLines.Add(string.Format("拒否: 行番号がファイルの行数を超えています。このファイルは {0}行、指定できるのは {1} までです", total, total + 1)); ExitCode = 1; return; }
        if (total == 0 && line > 1) { outLines.Add("拒否: 行番号がファイルの行数を超えています。このファイルは 0行、指定できるのは 1 までです"); ExitCode = 1; return; }
        
        ContentData cd = ReadContent(cFile);
        if (cd.error != null) { outLines.Add(cd.error); ExitCode = 1; return; }
        if (cd.lines.Length == 0) { outLines.Add("拒否: 内容ファイルが空です"); ExitCode = 1; return; }
        
        if (!(enc is UTF8Encoding)) {
            string cpErr = CheckCP932(cd.lines);
            if (cpErr != null) { outLines.Add(cpErr); ExitCode = 1; return; }
        }

        List<string> newLines = new List<string>();
        for (int i=0; i<line-1; i++) newLines.Add(fd.lines[i]);
        for (int i=0; i<cd.lines.Length; i++) newLines.Add(cd.lines[i]);
        for (int i=line-1; i<total; i++) newLines.Add(fd.lines[i]);
        
        bool hasnl = fd.hasTrailingNewline;
        string result = string.Join("\r\n", newLines.ToArray());
        if (hasnl) result += "\r\n";
        
        byte[] finalBytes = enc.GetBytes(result);
        using (FileStream fs = new FileStream(target, FileMode.Create, FileAccess.Write)) {
            if (fd.bom.Length > 0) fs.Write(fd.bom, 0, fd.bom.Length);
            fs.Write(finalBytes, 0, finalBytes.Length);
        }

        int newTotal = ReadFile(target, enc).lines.Length;
        
        outLines.Add(target);
        outLines.Add(string.Format("  挿入      {0}-{1}行", line, line + cd.lines.Length - 1));
        outLines.Add(string.Format("  ファイル  {0}行 → {1}行", total, newTotal));
    }

    static void RunCreate(string target, string cFile, List<string> outLines) {
        string err;
        string master = FindMaster(target, out err);
        if (master == null) { outLines.Add(err); ExitCode = 1; return; }
        BootConf conf = ReadBootConf(master);
        
        if (!IsSatoriFile(target)) {
            outLines.Add("拒否: 里々が読まない名前です。dic*.txt / replace.txt / replace_after.txt / satori_conf.txt のいずれかにしてください");
            ExitCode = 1;
            return;
        }

        if (!Directory.Exists(Path.GetDirectoryName(target))) {
            outLines.Add("拒否: フォルダがありません");
            ExitCode = 1;
            return;
        }

        if (File.Exists(target)) {
            outLines.Add("拒否: ファイルが既にあります");
            ExitCode = 1;
            return;
        }

        ContentData cd = ReadContent(cFile);
        if (cd.error != null) { outLines.Add(cd.error); ExitCode = 1; return; }
        if (cd.lines.Length == 0) { outLines.Add("拒否: 内容ファイルが空です"); ExitCode = 1; return; }
        
        Encoding enc = GetEncoding(conf, target);
        if (!(enc is UTF8Encoding)) {
            string cpErr = CheckCP932(cd.lines);
            if (cpErr != null) { outLines.Add(cpErr); ExitCode = 1; return; }
        }

        string result = string.Join("\r\n", cd.lines) + "\r\n";
        byte[] finalBytes = enc.GetBytes(result);
        File.WriteAllBytes(target, finalBytes);

        outLines.Add(target);
        outLines.Add(string.Format("  作成      {0}行", cd.lines.Length));
    }

    public static string[] Run(string cmd, string target, string workDir, string arg1, string arg2, string arg3) {
        ExitCode = 0;
        List<string> outLines = new List<string>();
        try {
            if (cmd == "list") RunList(target, outLines);
            else if (cmd == "find") RunFind(target, arg1, outLines);
            else if (cmd == "read") RunRead(target, arg1, arg2, outLines);
            else if (cmd == "write") RunWrite(target, arg1, arg2, arg3, outLines);
            else if (cmd == "insert") RunInsert(target, arg1, arg2, outLines);
            else if (cmd == "create") RunCreate(target, arg1, outLines);
            else {
                outLines.Add("不明なコマンドです: " + cmd);
                ExitCode = 1;
            }
        } catch(Exception ex) {
            outLines.Add("CRASH: " + ex.Message);
            ExitCode = 1;
        }
        return outLines.ToArray();
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

$ret = [SatoriDic]::Run($Command, $Target, $WorkDir, $Arg1, $Arg2, $Arg3)
$ret | ForEach-Object { Write-Output $_ }
exit [SatoriDic]::ExitCode





