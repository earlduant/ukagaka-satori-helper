# satori_runner.ps1
#
# SSP を介さずに satori.dll へ SHIORI イベントを送り、応答を取得する。
# 併せて、里々が「れしば」向けに出力する内部処理ログを受信する。
#
#   powershell -ExecutionPolicy Bypass -File satori_runner.ps1 <seq.txt> <ghost/master> <作業フォルダ> <savedata>
#
#     seq.txt       送るイベントを並べたファイル
#     ghost/master  本番のパスを渡す。runner が作業フォルダへコピーする
#     作業フォルダ  SKILL.md の「作業フォルダ」
#     savedata      持っていくセーブデータのパス。空文字なら持っていかない
#
#   4つとも必須。オプションは無い。
#
# 使い方
#   辞書を書いた後、最初に通す。里々が報告するエラーをここで潰す。
#   本番は読むだけで、書き換えない。里々が savedata を書き換えるのは作業フォルダのコピー。
#
#   応答の全文を読まない。1画面ぶんの UI はタグが数百個並んだ1行になる。
#   さくらスクリプトが壊れていないかは satori_script.ps1 で検査する。
#   期待と違う動きをしたら satori_log.ps1 で原因を辿る。
#
#   結果を利用者に見せない。修正方針を決めるためだけに使う。
#
# どの状態から始めるか
#   第4引数に渡したファイルを satori_savedata.txt として持っていく。
#
#     ""                            初期状態から始める
#     <本番>\satori_savedata.txt    本番の進行状況から始める
#     退避しておいた前回の結果      前回の続きから始める
#
#   本番の進行状況を使うと、同じ辞書でも利用者の状態によって結果が変わる。
#   再現性が要るなら空文字を渡し、状態は seq.txt で作る。
#
#     [OnSetup]        ← （set,進行度,5）などを呼ぶイベント
#
#     [OnTest]         ← 試したいイベント
#
# seq.txt の書式（UTF-8）
#
#   [イベント名]
#   Reference0: 値
#   Reference1: 値
#
#   [別のイベント名]
#
#   [イベント名] に続く行が、そのまま SHIORI ヘッダになる。# 始まりの行は無視。
#   同じイベントを何度書いてもよい。load から unload まで同じプロセスなので、
#   変数は保持される。連続する動作はここに並べて書く。
#
# 作業フォルダ
#   <作業フォルダ>\satori_runner\ を毎回消してからコピーする。
#   里々は同じフォルダの dic*.txt を全部読むので、前回の残骸があると
#   消したはずの辞書を読んでテストが狂う。
#   replace.txt や satori_bootconf.txt が古いままだと、結果が静かに狂う。
#
#   持っていくのは satori.dll satori_bootconf.txt satori_conf.txt replace.txt
#   replace_after.txt と、サブフォルダ（再帰）の dic*.txt と saori\ だけ。
#
# 出力
#   標準出力   イベントごとの応答
#   内部ログ   <作業フォルダ>\satori_runner\internal.log（常に出す）
#              必要になったら satori_log.ps1 で引く
#
# 内部ログの受信には4つの制約がある。
# どれも破ると、エラーにならないまま黙ってログが来なくなる。
#
#   1. 受信ウィンドウは load() より前に作る。
#      里々の FindWindow は生涯に一度しか走らない。最初にログを出そうとした時点で
#      ウィンドウが無ければ、以後そのプロセスでは二度と送信されない。
#   2. unload() まで破棄しない。
#      送信が ERROR_INVALID_WINDOW_HANDLE を返すと、里々は送信自体を停止する。
#   3. request() を呼ぶスレッドと同じスレッドで作る。
#      同一スレッド宛の送信はウィンドウプロシージャが直接呼ばれるので
#      メッセージループが要らず、request() から戻った時点でログが揃う。
#   4. ウィンドウプロシージャのデリゲートを保持し続ける（GC 回収の回避）。
#
# 里々は FindWindow(クラス名, ウィンドウ名) で両方を照合する。
# どちらも "れしば" にする。
#
# SHIORI/3.0 では load / request に渡した HGLOBAL の所有権が SHIORI 側へ移る。
# 呼び出し側が解放するとプロセスごと落ちる。解放するのは request の戻り値だけ。
#
# 里々とやり取りする文字列は Shift_JIS。内部ログは1メッセージが1行。
#
# 辞書の読み込みエラーは load() の戻り値に出ない（カッコの対応が壊れていても
# 成功が返る）。内部ログにしか出ないので、そこから拾う。
# 報告されるのはファイル名まで。行番号は出ない。
#
# satori.dll は 32bit。64bit で起動された場合は 32bit の PowerShell へ渡し直す。
#
# 終了コード
#   0  正常（里々が ErrorLevel を返した場合も 0。応答は取得できている）
#   2  引数が足りない、ファイルが無い
#   4  load 失敗
#   5  例外
#
# 応答が返らないことがある
#   閉じていない [ を含むさくらスクリプトを出力させると、里々がバッファの外を読む。
#   ] を探して読み進むので、何に当たるかはメモリの配置次第で結果が一定しない。
#
#     落ちる    AccessViolationException。このプロセスごと終了する。
#               .NET の catch では捕まえられないので、応答も終了コードも返らない
#     落ちない  ] が補完されるが、末尾に不定のゴミが混ざる
#
#   同じ辞書・同じ入力でも、実行のたびに変わる。
#   出力が途中で切れていたらこれを疑う。内部ログには load までの記録が残る。
#
#   SSP で動いている環境では発生しない。これはテスターの側で起きる現象なので、
#   利用者に辞書の誤りとして報告しない。
#
#   閉じていない [ を直せば起きなくなる。原因はそれだけで、他に調べることはない。
#   テスターの挙動や里々の内部を深追いしない。
#
# 事前のビルドは要らない。実行時に Add-Type が C# をコンパイルする。
#
# このファイルは BOM 付き UTF-8 で保存する。
# PowerShell 5.1 は BOM の無い UTF-8 を ANSI として読むため、
# 日本語が壊れ、C# のコンパイルも通らなくなる。

param(
    [Parameter(Position = 0)] [string] $SeqFile,
    [Parameter(Position = 1)] [string] $MasterDir,
    [Parameter(Position = 2)] [string] $WorkDir,
    [Parameter(Position = 3)] [AllowEmptyString()] [string] $SaveData
)

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$usage = @'
SSP を介さずに satori.dll へ SHIORI イベントを送り、応答を取得する。

  satori_runner.ps1 <seq.txt> <ghost/master> <作業フォルダ> <savedata>

    seq.txt       送るイベントを並べたファイル
    ghost/master  本番のパスを渡す。runner が作業フォルダへコピーする
    作業フォルダ  SKILL.md の「作業フォルダ」
    savedata      持っていくセーブデータのパス。空文字なら持っていかない

  内部ログは <作業フォルダ>\satori_runner\internal.log へ出る。
'@

if (-not $SeqFile -or -not $MasterDir -or -not $WorkDir) { Write-Output $usage; exit 2 }
if (-not (Test-Path $SeqFile))   { Write-Output "シーケンスファイルがありません: $SeqFile"; exit 2 }
if (-not (Test-Path $MasterDir)) { Write-Output "フォルダがありません: $MasterDir"; exit 2 }
if ($SaveData -and -not (Test-Path $SaveData)) { Write-Output "セーブデータがありません: $SaveData"; exit 2 }

# --- 32bit へ渡し直す -------------------------------------------------------
# satori.dll は 32bit。64bit プロセスからは呼べない

if ([Environment]::Is64BitProcess) {
    $ps32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps32)) { Write-Output "32bit の PowerShell が見つかりません: $ps32"; exit 2 }
    & $ps32 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $SeqFile $MasterDir $WorkDir $SaveData
    exit $LASTEXITCODE
}

# --- 準備 -------------------------------------------------------------------
# 前回の残骸があると、里々が古い辞書も読む（同じフォルダの dic*.txt を全部読む）

$runDir = Join-Path $WorkDir 'satori_runner'
if (Test-Path $runDir) { Remove-Item -Recurse -Force $runDir }
New-Item -ItemType Directory -Force $runDir | Out-Null

# 里々が読むものだけをコピーする。画像・音・フォント・shell は里々が扱わない
$copyNames = @(
    'satori.dll',
    'satori_bootconf.txt',
    'satori_conf.txt',
    'replace.txt',
    'replace_after.txt'
)
foreach ($n in $copyNames) {
    $src = Join-Path $MasterDir $n
    if (Test-Path $src) { Copy-Item $src $runDir }
}
Get-ChildItem $MasterDir -Filter 'dic*.txt' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($MasterDir.Length).TrimStart('\')
    $dest = Join-Path $runDir $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force $destDir | Out-Null }
    Copy-Item $_.FullName $dest
}

$saoriSrc = Join-Path $MasterDir 'saori'
if (Test-Path $saoriSrc) { Copy-Item $saoriSrc $runDir -Recurse }

# セーブデータは渡されたものだけを持っていく。どの状態から始めるかは呼ぶ側が決める
if ($SaveData) { Copy-Item $SaveData (Join-Path $runDir 'satori_savedata.txt') }

if (-not (Test-Path (Join-Path $runDir 'satori.dll'))) {
    Write-Output "satori.dll がありません: $MasterDir"
    exit 2
}
if (-not (Get-ChildItem (Join-Path $runDir 'dic*.txt') -File -ErrorAction SilentlyContinue)) {
    Write-Output "dic*.txt がありません: $MasterDir"
    exit 2
}

$code = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// ============================================================================
// SHIORI の呼び出し
// ============================================================================
// load / request に渡した HGLOBAL は SHIORI が解放する。呼び出し側では解放しない。
// 解放するのは request の戻り値だけ。

public class SatoriShiori
{
    [DllImport("satori.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern bool load(IntPtr h, int len);

    [DllImport("satori.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern bool unload();

    [DllImport("satori.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr request(IntPtr h, ref int len);

    [DllImport("kernel32.dll")]
    static extern IntPtr GlobalAlloc(int uFlags, int dwBytes);

    [DllImport("kernel32.dll")]
    static extern IntPtr GlobalFree(IntPtr hMem);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetDllDirectory(string lpPathName);

    public static readonly Encoding Enc = Encoding.GetEncoding(932);

    static IntPtr ToGlobal(string s, out int len)
    {
        byte[] bytes = Enc.GetBytes(s);
        len = bytes.Length;
        IntPtr h = GlobalAlloc(0x0040, len);
        Marshal.Copy(bytes, 0, h, len);
        return h;
    }

    // 渡すのは辞書フォルダのパス。末尾に区切り文字が要る
    public static bool Load(string dir)
    {
        SetDllDirectory(dir);
        int len;
        IntPtr h = ToGlobal(dir + Path.DirectorySeparatorChar, out len);
        return load(h, len);
    }

    public static string Request(string req)
    {
        int len;
        IntPtr h = ToGlobal(req, out len);
        IntPtr res = request(h, ref len);
        if (res == IntPtr.Zero || len <= 0) { return "(応答なし)"; }

        byte[] buf = new byte[len];
        Marshal.Copy(res, buf, 0, len);
        GlobalFree(res);
        return Enc.GetString(buf);
    }

    public static void Unload() { unload(); }
}

// ============================================================================
// 内部ログの受信
// ============================================================================
// 里々は「れしば」宛に WM_COPYDATA を送る。クラス名・ウィンドウ名ともに
// "れしば" のウィンドウを用意すれば受け取れる。

public class SatoriLog
{
    const string CLASSNAME = "れしば";
    const uint WM_COPYDATA = 0x004A;
    const uint CS_GLOBALCLASS = 0x4000;
    const uint PM_REMOVE = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    struct COPYDATASTRUCT
    {
        public IntPtr dwData;
        public int cbData;
        public IntPtr lpData;
    }

    delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX
    {
        public int cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int pt_x;
        public int pt_y;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "RegisterClassExW")]
    static extern ushort RegisterClassEx(ref WNDCLASSEX wcex);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateWindowExW")]
    static extern IntPtr CreateWindowEx(int dwExStyle, string lpClassName, string lpWindowName,
        uint dwStyle, int X, int Y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "DefWindowProcW")]
    static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "UnregisterClassW")]
    static extern bool UnregisterClass(string lpClassName, IntPtr hInstance);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "PeekMessageW")]
    static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max, uint remove);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "DispatchMessageW")]
    static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetModuleHandle(string lpModuleName);

    public static List<string> Lines = new List<string>();

    static WndProcDelegate holder;      // GC されるとネイティブから呼べなくなる
    static IntPtr window = IntPtr.Zero;
    static IntPtr instance = IntPtr.Zero;
    static StreamWriter writer = null;
    static int flushed = 0;

    static IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_COPYDATA)
        {
            try
            {
                COPYDATASTRUCT cds = (COPYDATASTRUCT)Marshal.PtrToStructure(lParam, typeof(COPYDATASTRUCT));
                if (cds.cbData > 0 && cds.lpData != IntPtr.Zero)
                {
                    byte[] data = new byte[cds.cbData];
                    Marshal.Copy(cds.lpData, data, 0, cds.cbData);
                    // cbData は終端 NUL を含む
                    Lines.Add(SatoriShiori.Enc.GetString(data).TrimEnd('\0'));
                }
            }
            catch (Exception ex)
            {
                Lines.Add("<<受信例外: " + ex.Message + ">>");
            }
            return (IntPtr)1;
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    public static bool Create()
    {
        holder = WndProc;
        instance = GetModuleHandle(null);

        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.style = CS_GLOBALCLASS;
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(holder);
        wc.hInstance = instance;
        wc.lpszMenuName = null;
        wc.lpszClassName = CLASSNAME;
        RegisterClassEx(ref wc);

        // 里々は FindWindow(クラス名, ウィンドウ名) で両方を照合する
        window = CreateWindowEx(0, CLASSNAME, CLASSNAME,
            0, 0, 0, 100, 100, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);

        return window != IntPtr.Zero;
    }

    public static void Destroy()
    {
        if (window == IntPtr.Zero) { return; }
        DestroyWindow(window);
        window = IntPtr.Zero;
        UnregisterClass(CLASSNAME, instance);
    }

    // 同一スレッド宛の送信はウィンドウプロシージャが直接呼ばれるが、
    // キューに積まれた場合に備えて吸い出す
    public static void Pump()
    {
        MSG msg;
        int guard = 0;
        while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE) && guard++ < 1000)
        {
            DispatchMessage(ref msg);
        }
    }

    public static void Open(string path)
    {
        Lines.Clear();
        flushed = 0;
        writer = new StreamWriter(path, false, new UTF8Encoding(false));
    }

    // 前回書いた位置から末尾までを、見出しを付けて書き出す
    public static void Flush(string header)
    {
        if (writer == null) { return; }
        writer.WriteLine("========== " + header + " ==========");
        for (int i = flushed; i < Lines.Count; i++) { writer.WriteLine(Lines[i]); }
        writer.WriteLine();
        writer.Flush();
        flushed = Lines.Count;
    }

    public static void Close()
    {
        if (writer == null) { return; }
        writer.Close();
        writer = null;
    }
}

// ============================================================================
// シーケンス
// ============================================================================

public class SatoriSeq
{
    public class Event
    {
        public string Name;
        public string Request;
    }

    public static List<Event> Parse(string path)
    {
        List<Event> list = new List<Event>();
        Event cur = null;
        StringBuilder sb = null;

        foreach (string raw in File.ReadAllLines(path, Encoding.UTF8))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) { continue; }

            if (line.StartsWith("[") && line.EndsWith("]"))
            {
                if (cur != null) { cur.Request = Close(sb); list.Add(cur); }

                cur = new Event();
                cur.Name = line.Substring(1, line.Length - 2).Trim();

                sb = new StringBuilder();
                sb.Append("GET SHIORI/3.0\r\n");
                sb.Append("Charset: Shift_JIS\r\n");
                sb.Append("Sender: SSP\r\n");
                sb.Append("SecurityLevel: local\r\n");
                sb.Append("ID: " + cur.Name + "\r\n");
                continue;
            }

            // 最初の [イベント名] より前の行は捨てる
            if (cur == null) { continue; }
            sb.Append(line + "\r\n");
        }
        if (cur != null) { cur.Request = Close(sb); list.Add(cur); }

        return list;
    }

    static string Close(StringBuilder sb)
    {
        sb.Append("\r\n");
        return sb.ToString();
    }
}

// ============================================================================
// 出力
// ============================================================================

public class SatoriReport
{
    // 辞書の読み込みエラーは load() の戻り値に出ない。内部ログから拾う
    public static void LoadErrors(List<string> log, List<string> output)
    {
        for (int i = 0; i < log.Count; i++)
        {
            if (log[i].IndexOf("カッコの対応関係") < 0) { continue; }

            output.Add("!!! 辞書の読み込みエラー !!!");
            if (i > 0) { output.Add("  " + log[i - 1]); }   // ファイル名は直前の行に出る
            output.Add("  " + log[i]);
            output.Add("  → このファイルの定義はすべて無効です。");
            output.Add("");
        }
    }

    // 里々はエラーを ErrorLevel / ErrorDescription ヘッダで返す
    public static bool HasError(string response)
    {
        return response.Contains("ErrorLevel:");
    }

    public static void Response(string name, string response, List<string> output)
    {
        output.Add("========== " + name + " ==========");
        if (HasError(response)) { output.Add("!!! 里々がエラーを報告しています !!!"); }
        output.Add(response.Trim());
        output.Add("");
    }
}

// ============================================================================
// 本体
// ============================================================================

public class SatoriRunner
{
    public static int ExitCode = 0;

    public static string[] Run(string seqFile, string runDir)
    {
        List<string> output = new List<string>();
        ExitCode = 0;

        seqFile = Path.GetFullPath(seqFile);
        runDir = Path.GetFullPath(runDir);
        string logFile = Path.Combine(runDir, "internal.log");

        string prevDir = Environment.CurrentDirectory;
        bool loaded = false;

        try
        {
            List<SatoriSeq.Event> events = SatoriSeq.Parse(seqFile);
            if (events.Count == 0)
            {
                output.Add("シーケンスにイベントがありません: " + seqFile);
                ExitCode = 2;
                return output.ToArray();
            }

            SatoriLog.Open(logFile);

            // 受信ウィンドウは load() より前に作る
            if (!SatoriLog.Create())
            {
                output.Add("受信ウィンドウを作れませんでした。内部ログは取得できません。");
                output.Add("");
            }

            Environment.CurrentDirectory = runDir;

            loaded = SatoriShiori.Load(runDir);
            SatoriLog.Pump();
            SatoriLog.Flush("load");

            SatoriReport.LoadErrors(SatoriLog.Lines, output);

            if (!loaded)
            {
                output.Add("load 失敗: " + runDir);
                ExitCode = 4;
                return output.ToArray();
            }

            int errors = 0;
            foreach (SatoriSeq.Event e in events)
            {
                string response = SatoriShiori.Request(e.Request);
                SatoriLog.Pump();
                SatoriLog.Flush(e.Name);

                if (SatoriReport.HasError(response)) { errors++; }
                SatoriReport.Response(e.Name, response, output);
            }

            if (errors > 0) { output.Add("里々がエラーを報告したイベント: " + errors + " 件"); }
            output.Add("内部ログ: " + logFile + " (" + SatoriLog.Lines.Count + " 行)");
        }
        catch (Exception ex)
        {
            output.Add("CRASH: " + ex.GetType().Name + ": " + ex.Message);
            output.Add(ex.StackTrace);
            ExitCode = 5;
        }
        finally
        {
            // 受信ウィンドウは unload() まで壊さない
            if (loaded)
            {
                SatoriShiori.Unload();
                SatoriLog.Pump();
                SatoriLog.Flush("unload");
            }
            SatoriLog.Close();
            SatoriLog.Destroy();
            Environment.CurrentDirectory = prevDir;
        }

        return output.ToArray();
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

[SatoriRunner]::Run($SeqFile, $runDir) | ForEach-Object { Write-Output $_ }
exit [SatoriRunner]::ExitCode

