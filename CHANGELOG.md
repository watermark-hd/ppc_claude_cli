# Changelog

**[English](#english) | [日本語](#japanese)**

<a id="english"></a>
## English

This file is not just a technical log — it's also where I want to say thanks to
whoever actually ran this thing on real hardware and noticed something was off.
If that's you, thank you.

### 2026-08-22

**Fixed:** Re-running the installer to upgrade no longer asks you to re-enter
your Anthropic API key.

Both `Install.command` and `setup.sh` used to ask "Overwrite? [y/N]" every
time `~/.claude-agent-env` already existed, and answering `y` (even by
accident) meant pasting the key in again. Now, if the key file already
exists, the installer just keeps it silently and prints a note on how to
delete the file first if you actually want to set a different key.

**Fixed:** Arrow keys no longer insert garbage characters instead of moving the cursor.

`claude-agent.pl` was reading input with a plain `<STDIN>`, which has no concept
of cursor movement. Pressing an arrow key while editing a line sent the
terminal's raw escape sequence (`ESC [ C`, `ESC [ D`, ...) straight into the
input as literal text instead of moving the cursor. Found by actually using the
agent interactively on the iBook and trying to fix a typo mid-line — thanks for
running it and reporting exactly what happened, that made this easy to track down.

Added a small stty-raw-mode line editor (no external CPAN dependency, in
keeping with the project's self-contained approach): left/right cursor
movement, backspace, and up/down input history, all aware of UTF-8 multi-byte
and full-width characters so Japanese input edits correctly too.

<a id="japanese"></a>
## 日本語

このファイルは技術的な変更履歴であると同時に、実際に手元のマシンで動かして
何かおかしいと気づいて教えてくれた方への感謝を書いておく場所でもあります。
使ってくれて、気づいてくれて、ありがとうございます。

### 2026-08-22

**修正:** インストーラーをアップグレードのために再実行しても、Anthropic APIキーの
再入力を求められないようにしました。

`Install.command`と`setup.sh`はどちらも、`~/.claude-agent-env`が既に存在する
場合に毎回「上書きしますか? [y/N]」と聞いており、うっかり`y`と答えるとキーの
貼り付けをやり直す羽目になっていました。今はキーファイルが既にあれば黙って
そのまま使い、別のキーに変えたい場合はファイルを削除してから実行し直す旨の
案内だけを表示するようにしています。

**修正:** 矢印キーを押すとカーソルが動かず、代わりに変な文字が入力されてしまう不具合。

`claude-agent.pl`はカーソル移動の概念を持たない単純な`<STDIN>`で入力を読んで
いたため、行編集中に矢印キーを押すと、ターミナルが送る生のエスケープシーケンス
(`ESC [ C`、`ESC [ D`など)がそのまま文字として入力されてしまっていました。
実際にiBook上でエージェントを対話的に使い、行の途中の誤字を直そうとして
気づいた不具合です。実際に使って、何が起きたかを教えてくれてありがとうござ
います。おかげで原因を特定しやすくなりました。

外部CPANモジュールに依存しないという方針(自己完結)に沿って、stty rawモード
による簡易的な行編集機能を自前で実装しました。←→でのカーソル移動、
Backspace、↑↓での入力履歴呼び出しに対応し、UTF-8のマルチバイト文字や全角
文字も考慮しているため、日本語入力の編集も正しく行えます。
