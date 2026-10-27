---
name: ukagaka-satori-helper
description: 里々（さとり / Satori SHIORI）で動く伺か（ukagaka）のゴーストを作る・直す。satori.dll と dic*.txt があるフォルダが対象。トークやセリフを足す、選択肢やメニュー・ステータス画面を作る、なでられ・つつかれなど既存の反応を直す、里々でそれが作れるかを判断する、といったとき。さくらスクリプト、サーフェス、バルーンの扱いも含む。
---

## 入っているもの

```
references\   引く。必要な節だけを読む
  syntax.md             里々の記法。辞書に触るなら通読する
  capabilities.md       作れるかどうかを判断する
  dialogue.md           利用者への提案・説明・依頼
  talk.md               トークを書く手順。断る基準もここ
  patterns.md           データを持つ・並べる型
  ui_architecture.md    専用画面の型。どこに表示を置くか
  display.md            バルーンの中の書き方
  internals.md          里々が黙ってやっていること
  testing.md            確かめ方

scripts\      実行する。使い方は各ファイルの冒頭コメントにある
  satori_dic.ps1        辞書を読み書きする。Shift_JIS を壊さない
  satori_runner.ps1     SSP を介さずにイベントを送り、応答を見る
  satori_script.ps1     返ったさくらスクリプトが壊れていないか検査する
  satori_lint.ps1       辞書を実行せずに検査する。里々の lint（ShioriLint）も付ける
  satori_log.ps1        里々の内部ログに問い合わせる
  Get-GhostInfo.ps1     動作中の SSP と里々から値を取る
```

`Get-GhostInfo.ps1` だけは、**カレントディレクトリをゴーストのルートにして呼ぶ。**
残りは対象を引数で受け取るので、どこから呼んでもよい。

---

## 里々と SSP は別のものである

里々は SHIORI である。イベントを受け取り、さくらスクリプトの文字列を
組み立てて返す。行うのはそれだけ。

SSP はベースウェアである。その文字列を解釈して実行する。
画面・音・入力・時間を持っているのは、すべて SSP の側。

```
里々   文字列を作る
SSP    その文字列が何を意味するかを決め、実行する
```

ここから6つが決まる。**個別の機能を調べる前に、これで切り分ける。**

**1. 辞書に書けるのは文字列までである。**

出したものがどう見えるか、どう鳴るか、いつ起きるかは SSP が決める。
辞書が正しくても、意図したとおりになるとは限らない。

**2. SSP が持つ情報は、辞書からは読めない。**

問い合わせて答えを受け取る形でしか手に入らない。
答えが返るのは SSP が動いているときだけ。

**3. さくらスクリプトの仕様は、里々の仕様ではない。**

「里々で書けるか」と「SSP が解釈するか」は別の問いである。
どちらも版で変わるが、変わり方は連動しない。

**4. 確かめられるのは、里々が返した文字列までである。**

それが SSP で何を起こすかは、実行した環境でしか分からない。
**確かめた範囲を超えて「動いた」と報告しない。**

**5. 辞書は自分から動き出せない。**

イベントが来たときだけ動く。
常に何かを見張り続ける形は、この時点で成立しない。

**6. さくらスクリプトの実行はシングルスレッドである。**

SSP は1本の列として、先頭から順に実行する。2つが同時に走ることはない。

**実行中に 200 で応答を返すと、実行中のものを破棄し、返した文字列を先頭から再生する。**
204 なら、実行中のものはそのまま続く。

今出ている文の途中に割り込む形にはならない。
どこまで実行されたかを知る手段も無い。

---

## 用語

### 作業フォルダ

使い捨ての一時フォルダ。スクリプトが `<作業フォルダ>` として受け取る。

エージェントが一時フォルダを持っているならそれでよい。
無ければ OS の一時領域の下に専用のフォルダを作る。

**作業フォルダとして、次の2つを渡さない**。スクリプトがこの中にファイルを作り、消す。

- 本番のゴーストフォルダ（`ghost\master` とその親）
- いま作業しているディレクトリ

`<作業フォルダ>` を受け取るのは `satori_runner` だけ。

---

## ghost\master の下は、すべて作業対象

退避やコピーを中に置かない。

サブフォルダの `dic*.txt` も、`＄辞書フォルダ` で切り替えたときに里々が読む。
検査もサブフォルダまで走る。

バックアップが要るなら、利用者に頼む。
作業フォルダは使い捨てなので、置き場所にならない。

---

## 進め方

依頼を受けたら、この順で進める。
既にあるものを直すだけなら、2 と 3 は飛ばしてよい。

**1. 辞書の文字コードを確かめる**

```
powershell -ExecutionPolicy Bypass -File scripts\satori_dic.ps1 list <ghost\master>
```

「Shift_JIS が混じります」が返ったら、**以後の辞書の読み書きはすべて
`scripts\satori_dic.ps1` を通す。**直接編集すると文字化けし、元に戻せない。
「UTF-8 です」なら直接編集してよい。

**2. 里々で作れるかを判断する** ── `references\capabilities.md`

作れないものの細部を聞き出しても、聞いた分だけ無駄になる。

**3. 何を作るかを決めて、提示する** ── `references\dialogue.md`

答えを持っていない相手に、判断を投げない。却下されてから読むのでは遅い。

**4. 既存の辞書を読む**

`ghost\master` の `dic*.txt`。サブフォルダも含む。
何本あって、どれに何が書かれているかを掴んでから触る。
口調も書き方も、既にあるものに合わせる。

**5. 書く** ── `references\syntax.md` を通読する

何を作るかで引くものが変わる。下の「参照先」を見る。

**6. 通す** ── `references\testing.md`

里々は、誤りがあっても止まらない。誤りは自分から見に行かないと見つからない。**動かさずに「書けた」と報告しない。**

**7. 報告する** ── `references\dialogue.md`

**確かめた範囲を超えて「動いた」と報告しない。**

---

## 参照先

依頼の内容によって引くもの。引くときは目次で節名を見てから、その節だけを読む。

通常の会話とは違う画面を作る（ミニゲーム、ステータス画面、専用メニュー）、
絵を動かす、利用者にウィンドウを掴んで動かさせる ── このいずれかなら、
どこに表示を置くか決める前に `references\ui_architecture.md` を引く。
バルーンに出すかシェルに出すかで、用意するものも崩れ方も変わる。

複数のデータを持って表示する（一覧・メニュー・図鑑）、
件数が増えるものを記録する ── このいずれかなら、
書く前に `references\patterns.md` を引く。通読しなくてよい。

バルーンに文字を並べて形を作る（枠・表・バー・メニュー）、
一度出したものを消して描き直す、
途中で止めたくない／割り込ませたくないトークを書く ── このいずれかなら、
書く前に `references\display.md` を引く。通読しなくてよい。

セリフを書く ── このときは、
書き出す前に `references\talk.md` を引く。
そのゴーストの辞書を読まずに書くと、口調も題材も合わない。

書いた覚えのない動きをする、書いたのに動かない、
里々が自動でやっていることを止めたい・作り変えたい ── このいずれかなら、
`references\internals.md` を引く。
里々が肩代わりしている処理なので、辞書を探しても原因が見つからない。

複数に当たることがある。そのときは上から順に引く。
どこに置くかが決まらないと、データの持ち方も、表示の書き方も決まらない。

---

## 仕様を引く

里々の関数、さくらスクリプトのタグ、SHIORI イベント名 ──
名前や書式が分からないものに当たったら、引く。

**未知の仕様を推測で書かない**。必ず引いて確かめる。
引くとは、下のどれかの手段で仕様書を読むこと。MCP は早く引くための道具で、無くても引ける。
どの手段でも確かめられなければ、何が確かめられなかったかを利用者に伝える。

引き方は、`ukagaka-doc` MCP があるかどうかで分かれる。

```
ukagaka-doc の search_docs が使える  → MCP から引く。引き方を変えても見つからなければ、ページを直接読む
無い                                 → ページを直接読む
```

### MCP から引く

`search_docs` はクエリ文字列全体の部分一致しか行わない。
スペース区切りの複数語は AND 検索にならず、その並びのまま探す。
`mouse click` は `OnMouseDoubleClick` にヒットしない。

**投げるのは、スペースを含まない単語1つ。**
`OnSurfaceRestore` `\_l` `サーフェス戻し` のように、記号もそのまま入れてよい。

**0件は「存在しない」ではなく「引き方が違う」。**
複合語は分解し、日本語の説明語・英語のタグ名・上位概念の3方向から引く。

`source` で絞れる。使える値は `search_docs` の説明に並ぶもので、MCP の版で違う
（里々は `satori_docs`、古い版は `satori_wiki`）。並んでいなければ付けずに引く。

**大文字と小文字は区別されない。**`\C` で引くと `\c` も出て、先に並ぶことがある。
大文字と小文字だけが違うタグは、UKADOC の一覧で確かめる。

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

どれも1項目1ファイルの Markdown。`index.md` は分類の一覧で、リンクを辿ると項目のファイルに着く。
リンクは相対パスなので、開いたファイルの場所を基準に URL を組み立てる。

**ファイル名からは引けない。**`\![execute,filewatch]` は `bang-execute-filewatch.md` になる。
分類の一覧に並ぶタグ名・関数名で探す。

里々の関数は2か所に分かれる。片方で見つからなければ、もう片方を見る。

**里々の仕様書は新しい Unicode 版（`Mc2XX`）のもの**。ゴーストの `satori.dll` はもっと古いことがある。
載っていても、その版で同じに動くとは限らない。テスターで確かめ、違えば `references\dialogue.md`「satori.dll が古くて動かないとき」。

**開けなければ、表の「全体の案内」から辿り直す。それでも開けなければ Web 検索する**。URL が変わったか、サイトが移った可能性がある。
そこで止まらない。`site:ukatech.shillest.net` や `里々 <関数名>` のように対象を絞る。
