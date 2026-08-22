# Changelog

**[English](#english) | [日本語](#japanese)**

<a id="english"></a>
## English

This file is not just a technical log — it's also where I want to say thanks to
whoever actually ran this thing on real hardware and noticed something was off.
If that's you, thank you.

### 2026-08-22

**Fixed:** Typing at the prompt (any character, not just Japanese) no longer
pushes the terminal down one new line per keystroke instead of editing in
place.

The line editor redraws the current line with `"\r\x1b[K"` (return to column
0, erase to end of line) after every keystroke. `stty raw -echo` disables
input processing, but on some systems output post-processing (`opost`) is
left on, and if `ocrnl` is part of that, every `\r` we print gets turned into
a newline instead of actually returning to column 0 — so each redraw lands on
a fresh line instead of overwriting the one before it. Found from a real
iBook session where even plain ASCII input scrolled a new line per
keystroke, which ruled out the multi-byte decode fix below as the sole cause.
Fixed by explicitly disabling `opost` alongside `raw -echo`.

**Fixed:** Typing Japanese (or any multi-byte UTF-8) text at the prompt no
longer fills the screen with garbled "◆" replacement characters.

The line editor added to fix arrow-key handling read input one raw byte at a
time and redrew the line after every single byte. A multi-byte UTF-8
character (all Japanese text is 3 bytes per character) would briefly exist as
an incomplete, invalid byte sequence between reads, and the redraw's UTF-8
decode replaced that invalid partial sequence with a "◆" placeholder — once
per byte, for every character typed. Found from a screenshot of an actual
iBook session showing the terminal filling up with these placeholders while
typing a Japanese prompt. Fixed by reading all the bytes of a character
before inserting it into the buffer and redrawing.

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

**修正:** プロンプトで何か入力するたびに(日本語に限らず)、その場で編集されず
1キーごとに新しい行へどんどん改行されていってしまう不具合。

行編集機能は、1キー入力するたびに`"\r\x1b[K"`(先頭に戻ってその行を消す)で
現在行を再描画しています。`stty raw -echo`は入力側の処理を無効にしますが、
環境によっては出力側の後処理(`opost`)が有効なままのことがあり、その中に
`ocrnl`が含まれていると、出力する`\r`が改行として扱われてしまい、本来同じ
行を上書きするはずが毎回新しい行に描画されてしまいます。実際のiBookで
半角英数字を打っただけでも1文字ごとに改行されていくのを確認し、これによって
下記のマルチバイトデコードの修正だけが原因ではないと判明しました。
`raw -echo`と合わせて`opost`も明示的に無効化することで修正しました。

**修正:** 日本語(マルチバイトのUTF-8文字)を入力すると、画面が文字化けした
「◆」だらけになってしまう不具合。

矢印キー対応のために追加した行編集機能は、入力を生バイト単位で1バイトずつ
読み、そのたびに行を再描画していました。日本語などのマルチバイトUTF-8文字
(日本語は1文字3バイト)は、全バイトが揃うまでの間、一時的に不完全で不正な
バイト列になります。再描画時のUTF-8デコードがこの不正な部分列を「◆」
(置換文字)に変換してしまうため、1文字打つたびに、揃うまでの間そのバイト数分
「◆」が表示される作りになっていました。実際のiBookでのセッションの
スクリーンショットで、日本語プロンプトを入力中に画面が「◆」で埋まっている
のを見て発見しました。1文字分のバイトが揃ってからバッファに追加・再描画する
ように修正しました。

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
