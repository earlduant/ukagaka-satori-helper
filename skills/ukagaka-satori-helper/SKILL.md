---
name: ukagaka-satori-helper
description: 里々（さとり / Satori SHIORI）で動く伺か（ukagaka）のゴーストを作る・直す。satori.dll と dic*.txt があるフォルダが対象。トークやセリフを足す、選択肢やメニュー・ステータス画面を作る、なでられ・つつかれなど既存の反応を直す、里々でそれが作れるかを判断する、といったとき。さくらスクリプト、サーフェス、バルーンの扱いも含む。
---

## 入っているもの

```
references\   引く。syntax.md 以外は丸読みせず、目次を見て必要な節の行範囲だけ読む
  syntax.md             里々の記法コア。辞書に触るなら通読する
  syntax_ref.md         関数・変数・壊れやすい細部の事典。必要な節だけ引く
  capabilities.md       作れるかどうかを判断する
  dialogue.md           利用者への提案・説明・依頼・報告
  talk.md               トークを書く手順と、触り反応の扱い
  patterns.md           データを持つ・並べる・設定を外に出す型
  ui_architecture.md    専用画面の型。どこに表示を置くか
  display.md            バルーンの中の書き方
  internals.md          里々が黙ってやっていること（症状別の逆引きもここ）
  testing.md            確かめ方

scripts\      実行する（詳細・例は各ファイルの冒頭コメントにある）
  satori_dic.ps1        辞書を読み書きする。Shift_JIS を壊さない
  satori_runner.ps1     SSP を介さずにイベントを送り、応答を見る（以後「テスター」と呼ぶ）
  satori_script.ps1     返ったさくらスクリプトが壊れていないか検査する
  satori_lint.ps1       辞書を実行せずに検査する。里々の lint（ShioriLint）も付ける
  satori_log.ps1        里々の内部ログに問い合わせる
  Get-GhostInfo.ps1     動作中の SSP と里々から値を取る
```

### スクリプト実行チートシート

`scripts\` はこの SKILL.md からの相対パス。引数はすべて必須（空文字 `""` が必要な箇所あり）。

```powershell
# 辞書操作（Shift_JIS が混じるゴーストでは read_file/直接編集ではなく必ずこれを使う）
powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 list <ghost\master>
powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 find <ghost\master> <語>
powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 read <辞書ファイル> <開始行> <終了行>
powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 write <辞書ファイル> <内容ファイル> <開始行> <終了行>
powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 insert <辞書ファイル> <内容ファイル> <行番号>
powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 create <辞書ファイル> <内容ファイル>

# 検査・テスト・情報取得
powershell -ExecutionPolicy Bypass -File scripts\satori_lint.ps1 <ghost\master>
powershell -ExecutionPolicy Bypass -File scripts\satori_runner.ps1 <seq.txt> <ghost\master> <作業フォルダ> <savedata|"">
powershell -ExecutionPolicy Bypass -File scripts\satori_script.ps1 <runner出力ファイル>
powershell -ExecutionPolicy Bypass -File scripts\satori_log.ps1 <internal.log> <problems|event|trace> <語|"">
powershell -ExecutionPolicy Bypass -File scripts\Get-GhostInfo.ps1 <ghost\master> -Name <名前>
```

---

## 里々と SSP は別のものである

里々は SHIORI である。イベントを受け取り、さくらスクリプトの文字列を組み立てて返す。行うのはそれだけ。

SSP はベースウェアである。その文字列を解釈して実行する。画面・音・入力・時間を持っているのは、すべて SSP の側。

```
里々   文字列を作る
SSP    その文字列が何を意味するかを決め、実行する
```

ここから6つが決まる。**個別の機能を調べる前に、これで切り分ける。**

1. **辞書に書けるのは文字列までである。** 出したものがどう見えるか、どう鳴るか、いつ起きるかは SSP が決める。辞書が正しくても、意図したとおりになるとは限らない。
2. **SSP が持つ情報は、辞書からは読めない。** 問い合わせて答えを受け取る形でしか手に入らず、返るのは SSP が動いているときだけ。
3. **さくらスクリプトの仕様は、里々の仕様ではない。** 「里々で書けるか」と「SSP が解釈するか」は別の問いで、版の変化も連動しない。
4. **確かめられるのは、里々が返した文字列までである。** SSP で何を起こすかは実行環境でしか分からない。**確かめた範囲を超えて「動いた」と報告しない。**
5. **辞書は自分から動き出せない。** イベントが来たときだけ動く。常時監視は成立しない。
6. **さくらスクリプトの実行はシングルスレッドである。** 実行中に 200 で返すと実行中のものは破棄され、先頭から再生される（204 は継続、先頭 `\C` だけは出し切ってから続く → `capabilities.md`「実行の途中には手を出せない」）。今出ている文の途中に割り込む形にはならず、どこまで実行されたかを知る手段も無い。

---

## 用語

### 作業フォルダ

`satori_runner.ps1` だけが受け取る使い捨ての一時フォルダ。エージェントが一時領域を持っているならそれを使い、無ければ OS の一時領域の下に専用フォルダを作る。使い捨てなので控えの置き場所にはならない。

スクリプトがこの中でファイルを作り消すため、**次の2つは絶対に渡さない**：

- 本番のゴーストフォルダ（`ghost\master` とその親）
- いま作業しているディレクトリ

---

## ghost\master の下は、すべて作業対象

- サブフォルダの `dic*.txt` も `＄辞書フォルダ` で読まれ、検査もサブフォルダまで走る。退避やコピーを `ghost\master` の中に置かない
- `satori.dll` の差し替え等で控えを取るときは `ghost\master_backup` のように `master` の外へ置く（→ `dialogue.md`「satori.dll が古くて動かないとき」）

---

## 必ず守る不変条件と依頼別の進め方

### 不変条件（すべての依頼で厳守）

1. **編集前に文字コードと里々の版を確かめる**: `satori_dic.ps1 list <ghost\master>` を実行し、「Shift_JIS が混じります」が返ったら**以後の読み書きはすべて `satori_dic.ps1` を通す**（直接編集で文字化けすると戻せない）。「UTF-8 です」なら直接編集可。出力の `里々: phase Mc…` と `references\` の版条件を比べ、満たさない書き方は避ける。
2. **作業領域の境界を守る**: `ghost\master` に一時ファイルや退避を置かない。
3. **未知の仕様を推測で書かない**: 関数・タグ・イベント名は仕様を引いて確かめる。
4. **辞書に触れたら検証を通す**: 里々は誤りがあっても止まらない。セリフを書いただけでも `satori_lint.ps1` を通し、処理や画面を触ったらテスター（`satori_runner.ps1`）と `satori_script.ps1` まで通す（→ `testing.md`）。
5. **確かめた範囲を超えて「動いた」と報告しない**: 画面の見え方など実機確認が要る部分は具体的に依頼する（→ `dialogue.md`「報告する」）。

### 依頼タイプ別の進め方

依頼の性質に応じて必要な段階だけ踏む（既にあるものを直すだけなら相談・提案を挟まず調査と修正へ進んでよい）。

| 依頼のタイプ | 進め方の要点と理由 |
|---|---|
| **作れるかの相談・可否判断** | `capabilities.md` で可否と境界を切り分け、できない部分は同じ場で代案を添えて答える（`dialogue.md`）。作れないものの細部を聞き出しても無駄になるため |
| **原因調査・バグ修正** | `internals.md` の逆引きや `satori_dic.ps1` / `testing.md` で原因と利用箇所（`find`）を特定してから直し、検証を通す |
| **トーク・セリフの追加** | `syntax.md` を読み、既存辞書の構成・口調・題材を掴んでから `talk.md` の手順で別辞書へ書き、`satori_lint.ps1` を通す |
| **機能・専用画面の新規作成** | `capabilities.md` で可否確認 → 既存辞書（口調・構成）を見てから `dialogue.md` に沿って形の案を提示（答えを持たない相手に細部の判断を投げず、却下後に読まないため）→ `syntax.md` と下の逆引きで設計・実装（調整値は `＠` で先頭に置く → `patterns.md`）→ `testing.md` で全検証 → 報告 |

---

## 目的・症状別の逆引き

複数に当てはまる場合は上から順に引く（どこに置くかが決まらないと、データの持ち方や表示も決まらない）。

| やりたいこと・起きた症状 | 最初に引くファイル |
|---|---|
| 里々で作れるか判断したい、できる範囲・限界を知りたい | `capabilities.md` |
| 通常会話と違う画面（ミニゲーム、ステータス画面、専用メニュー）、絵を動かす、掴ませる | `ui_architecture.md` |
| 複数のデータを持って並べる（一覧・メニュー・図鑑）、件数が増える記録、調整値の設定化 | `patterns.md` |
| バルーンに文字・画像・枠・表を並べる、消して描き直す（`\C`・`\b[-1]`）、割り込ませないトーク | `display.md` |
| トークやセリフを書き足したい、触り反応を頼まれた | `talk.md` |
| 書いた覚えのない動きをする、書いたのに動かない、内蔵処理（なで・戻し等）を変えたい | `internals.md` |
| 利用者への提案・用語選び・確認依頼・報告のしかた | `dialogue.md` |
| 関数・変数・条件式・エスケープ・タグなどの詳細仕様を引きたい | `syntax_ref.md` |
| `satori_lint` / テスター / `Get-GhostInfo` の使い方や結果の読み方 | `testing.md` |

---

## 仕様を引く

里々の関数、さくらスクリプトのタグ、SHIORI イベント名 ── 名前や書式が分からないものに当たったら必ず引く。どの手段でも確かめられなければ、何が確かめられなかったかを利用者に伝える。

- `search_docs` / `get_doc` / `list_categories` 等を提供する伺か仕様書 MCP（サーバー名は環境により `ukagaka-doc` や `ukadoc` 等）が使える → **MCP から引く**。見当たらなければ下のページを直接読む
- 使えない → **下のページを直接読む**

### MCP から引く

- `search_docs` はクエリ文字列全体の部分一致しか行わない。スペース区切りの複数語は AND 検索にならず、`mouse click` は `OnMouseDoubleClick` にヒットしない。**投げるのはスペースを含まない単語1つ**（`OnSurfaceRestore` `\_l` `サーフェス戻し` 等）
- **0件は「存在しない」ではなく「引き方が違う」**。複合語は分解し、日本語の説明語・英語のタグ名・上位概念の3方向から引く
- `source` で絞れる（値は `search_docs` の説明に出る。例：`satori_docs` / `satori_wiki`）。並んでいなければ付けずに引く
- **大文字と小文字は区別されない**。`\C` で引くと `\c` も出るため、大文字小文字だけが違うタグは UKADOC の一覧で確かめる

### ページを直接読む

**UKADOC** ── SSP とさくらスクリプトの仕様書

| | |
|---|---|
| 全体の案内 | `https://ukatech.shillest.net/ukadoc-spec/llms.txt` |
| さくらスクリプト | `https://ukatech.shillest.net/ukadoc-spec/list/sakura-script/index.md` |
| SHIORI イベント | `https://ukatech.shillest.net/ukadoc-spec/list/shiori-event/index.md` |
| SHIORI リソース | `https://ukatech.shillest.net/ukadoc-spec/list/shiori-resource/index.md` |
| プロパティシステム | `https://ukatech.shillest.net/ukadoc-spec/list/propertysystem/index.md` |
| ゴーストの `descript.txt` | `https://ukatech.shillest.net/ukadoc-spec/descript/ghost/index.md` |
| シェルの `descript.txt` | `https://ukatech.shillest.net/ukadoc-spec/descript/shell/index.md` |
| `surfaces.txt` | `https://ukatech.shillest.net/ukadoc-spec/descript/shell-surfaces/index.md` |
| バルーンの `descript.txt` | `https://ukatech.shillest.net/ukadoc-spec/descript/balloon/index.md` |

**里々の仕様書** ── 里々の関数と変数

| | |
|---|---|
| 全体の案内 | `https://ukatech.shillest.net/satori-docs/llms.txt` |
| 内蔵関数（`set` `when` など） | `https://ukatech.shillest.net/satori-docs/functions/index.md` |
| ssu の関数（`calc` `substr` など） | `https://ukatech.shillest.net/satori-docs/ssu/index.md` |
| システム変数・組み込み名 | `https://ukatech.shillest.net/satori-docs/system/index.md` |
| エラーメッセージ | `https://ukatech.shillest.net/satori-docs/other/error-messages.md` |
| ACP 版（`Mc1XX`）との違い | `https://ukatech.shillest.net/satori-docs/other/unicode-changes.md` |

- どれも1項目1ファイルの Markdown。`index.md` は分類一覧で、相対リンクを辿って項目ファイルを開く
- **ファイル名からは引けない**（`\![execute,filewatch]` → `bang-execute-filewatch.md`）。一覧に並ぶタグ名・関数名で探す。里々の関数は `functions/` と `ssu/` の2か所に分かれる
- **里々の仕様書は新しい Unicode 版（`Mc2XX`）のもの**。古い `satori.dll` では動かない関数もあるためテスターで確かめる（→ `dialogue.md`「satori.dll が古くて動かないとき」）
- 開けなければ「全体の案内」から辿り直すか Web 検索する（`site:ukatech.shillest.net` や `里々 <関数名>`）。そこで止まらない
