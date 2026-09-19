# ukagaka-satori-helper

里々（さとり）で動く伺かのゴーストを、AI と一緒に作る・直すための道具です。

AI に里々のことを教え、**できないことは「できない」と言わせる**ためのものです。
里々は資料が少ないので、放っておくと AI は知ったかぶりをします。それを止めます。

---

## 必要なもの

| | |
|---|---|
| AI と会話できる開発道具 | Claude Code、Codex、Antigravity など |
| 里々で動くゴースト | `satori.dll` と `dic*.txt` が入っているもの |
| Windows | 中の検査ツールが PowerShell で書かれています |

シェル（絵）は既にあるものとして扱います。**絵は描けません。**

---

## インストールの一例：Claude Code の場合

ゴーストのフォルダで Claude Code を開いて、

```
claude plugin marketplace add earlduant/ukagaka-satori-helper
claude plugin install ukagaka-satori-helper --scope project
```

開くのは `ghost` と `shell` が並んでいる階層です。その中の `master` ではありません。

```
Ｒポストと狛犬\        ← ここ
  ghost\master\satori.dll
  shell\
```

### 入れたあと

**Claude Code をいったん終了して、開き直します。**入れた直後のセッションには読み込まれません。

開き直したら、

```
claude plugin list
```

`ukagaka-satori-helper` が出れば成功です。

| | |
|---|---|
| `--scope project` | いま開いているゴーストだけ |
| `--scope user` | どのプロジェクトでも |
| `claude plugin uninstall ukagaka-satori-helper` | 消す |

### Claude Code に任せる場合

チャットでこう頼めば、同じことをやってくれます。

```
github の earlduant/ukagaka-satori-helper を、このプロジェクトに入れて
```

---

## インストールの一例：Codex / Antigravity の場合

このページの **Code** → **Download ZIP** で落として展開し、
中の `skills\ukagaka-satori-helper\` を、ゴーストのフォルダの `.agents\skills\` へ置きます。

```
Ｒポストと狛犬\
  .agents\
    skills\
      ukagaka-satori-helper\
        SKILL.md
        references\
        scripts\
  ghost\
  shell\
```

`.agents` は Codex と Antigravity で共通です。
どのプロジェクトでも使うなら、置き場所が変わります。

| | |
|---|---|
| Codex | `%USERPROFILE%\.agents\skills\` |
| Antigravity | `%USERPROFILE%\.gemini\antigravity\skills\` |

### 置いたあと

**いったん終了して、開き直します。**置いた直後には読み込まれません。

開き直してから、里々のことを何か頼んでみてください。
`references\` を読みにいく様子が見えれば、読み込まれています。

---

## 使いかた

日本語でそのまま頼むだけです。

```
持ち物の一覧画面を作りたい
里々で好感度を覚えさせられる？
集めたものを並べる図鑑を作って
なでたときの反応が出なくなった。原因を調べて
```

必要になった資料を AI が自分で読みにいきます。

---

## できること

| | |
|---|---|
| 画面を作る | 選択肢、メニュー、一覧など |
| 判断する | 「里々でそれが作れるか」を、調べたうえで答える |
| 辞書を直す | 誤字、条件の間違い、動かない箇所 |
| 確かめる | 書いた辞書を実際に動かし、壊れていないか検査する |

---

## 中身

```
skills\ukagaka-satori-helper\
  SKILL.md          最初に読まれるもの
  references\       里々の記法、判断材料、確かめ方（9本）
  scripts\          辞書の検査・動作テスト（6本）
```

`scripts\` は AI が自分の書いたものを確かめるために使います。直接実行する場面はありません。

---

## ライセンス

MIT License

同梱物に里々本体（`satori.dll`）は含まれていません。
里々で動いているゴーストには、既に入っています。
