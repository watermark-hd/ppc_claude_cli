# Changelog

**[English](#english) | [日本語](#japanese)**

<a id="english"></a>
## English

This file is not just a technical log — it's also where I want to say thanks to
whoever actually ran this thing on real hardware and noticed something was off.
If that's you, thank you.

### 2026-08-28

**Added:** Gemini (Google) support as an alternative to Anthropic. `setup.sh` now asks
which one to use up front — Gemini's free tier needs no credit card at all, which turned
out to be the single biggest thing standing between "cool project" and someone actually
trying it, based on reaction to this project on the MacRumors PowerPC Macs forum.

Under the hood, conversation history is kept in one internal shape (Anthropic's) regardless
of provider, and only translated to/from Gemini's `contents`/`parts`/`functionCall` format
right at the API call boundary — so the terminal input handling and tool execution, the
bulk of this file, needed zero changes.

**Found (the hard way) and fixed:** Gemini 3 requires echoing back an opaque
`thoughtSignature` on the exact `functionCall` part it was attached to, or the next turn
in a multi-tool-call conversation 400s. This was optional on Gemini 2.5 and became a hard
requirement on 3 — found by watching a real multi-step tool-calling conversation
(`list_dir` → `run_shell` → `run_shell` → `list_dir`) fail on the second tool call once
signatures weren't being carried along, on the actual iBook.

**Fixed:** Reading the API response could corrupt Japanese (or any multi-byte) text with a
`utf8 "\xXX" does not map to Unicode` warning — the exact same PerlIO `:encoding(UTF-8)`
buffer-boundary bug already fixed for STDIN reads back in the entries below, just showing
up on the response-reading side this time. Surfaced when a `run_shell` result happened to
contain a folder named `ダウンロード`. Same fix: read raw bytes, decode the whole thing at
once afterward.

**Changed:** The command is now `advisor` instead of `claude`. Typing `claude` to talk to
Gemini was a guaranteed "wait, is this even working?" moment, and this project isn't really
about any one company's AI — the point was always giving the old machine somewhere to
answer questions, not which brand answers them.

**Added:** Typing `/claude` or `/gemini` mid-conversation switches providers on the fly,
carrying the conversation over. If the target's key isn't set yet, it's prompted for right
there (hidden, like a password field) — Esc or Ctrl+C backs out cleanly instead.

**Fixed:** Gemini requests were a lot slower than they needed to be — a plain "what's the
main ingredient of beer?" took roughly 30 seconds on the actual iBook. Gemini 3 models
default to `thinkingLevel` "HIGH" (maximum internal reasoning) whenever the request doesn't
set it, and nothing here was setting it. Now defaults to "LOW" for snappier answers on
casual questions, overridable with `CLAUDE_GEMINI_THINKING=high` for anything that
genuinely needs deeper reasoning (Gemini 2.5 models get the equivalent via
`thinkingBudget` instead, since that series doesn't have `thinkingLevel`). Applied the same
fix to `setup.sh`'s and `Install.command`'s connectivity checks, which had the identical
problem.

**Fixed:** The double-click installer (`Install.command`, the one that ships in the
distributed zip) still only knew about Anthropic — the Gemini provider choice had only
ever made it into `setup.sh`, the source-build path. Ported the same up-front "Anthropic or
Gemini" prompt into `Install.command`, and renamed its installed command from `claude` to
`advisor` to match. `README.txt` inside the zip updated to match.

**Changed:** Default Gemini model switched from `gemini-3.6-flash` to
`gemini-3.5-flash-lite`. Found the hard way, on the actual iBook: the free tier for
`gemini-3.6-flash` allows only 20 requests *per day* — trivially used up just installing
and testing — while `flash-lite` tiers get a far larger free daily allowance. Casual
day-to-day questions don't need the newest model anyway; anyone doing serious/business-grade
work would be reaching for a modern machine, not this one. Override with `CLAUDE_MODEL` if
you want the newer model back.

**Fixed:** Asking the agent to fetch a URL (e.g. "summarize this website") could take five
separate `run_shell` attempts, each needing its own y/N confirmation, before one finally
worked — the system's stock `curl` can't do HTTPS at all (no TLS 1.2), and the model kept
guessing modern Python 3 syntax (`urllib.request`, `except X as e:`) against Tiger's old
Python 2. The agent already has a TLS-capable curl available to it internally, and it turns
out that's inherited into every `run_shell` subprocess too, via the `$CLAUDE_CURL` (and
`$CLAUDE_CACERT`) environment variables the `advisor` wrapper script exports — the system
prompt just never mentioned it. Added a short note about both quirks (use `$CLAUDE_CURL`
for HTTPS, assume old Python 2 syntax) so the right approach gets picked on the first try.

### 2026-08-22

**Fixed:** Typing a line long enough to wrap past the terminal's width filled
the screen with the same line repeated over and over — every keystroke,
Backspace, arrow-key edit, and Up/Down history recall left another copy of
the wrapped text behind instead of editing in place. Found from a screenshot
of an actual iBook session showing a wall of identical prompts. The line
editor's redraw only did "clear the current row, then reprint" before every
edit; once the input wrapped onto more than one terminal row, that only ever
cleared the last of those rows, so the earlier ones from the previous redraw
were never touched. Fixed by tracking how many rows the previous redraw
occupied, moving the cursor back to the top of that block, and clearing
everything from there to the end of the screen before repainting — verified
with a pty + a virtual-terminal renderer, covering long wrapping input,
Backspace, Left/Right, and Up/Down history recall of both short and
wrapping entries.

**Fixed:** Japanese (and presumably other IME-composed) text was still
garbled after all the fixes above, because Terminal.app on this iBook sends
each byte of IME-committed text prefixed with a literal `0x16` (Ctrl-V) —
the traditional Unix terminal "LNEXT" signal meaning "take the next
character literally" — even though this program's line editor puts the
terminal in raw mode and doesn't interpret that signal itself, so the
`0x16` bytes were landing in the buffer as garbage and corrupting the UTF-8.
Found by adding a temporary debug-logging mode to the line editor
(`CLAUDE_DEBUG_INPUT=path claude`) and capturing the actual bytes from a
real session: typing "トウキョウト" produced `16 e3 16 83 16 88 16 e3 16 82
16 a6 ...` — strip out every `16` and what's left,
`e3 83 88 e3 82 a6 ...`, is perfectly valid UTF-8 for exactly that word.
Plain ASCII typed directly (not via IME) had no `0x16` bytes at all, which
is why this only ever affected Japanese input. Fixed by having the line
editor strip each `0x16` and treat the byte after it as the real one,
verified by feeding this exact captured byte sequence through a test
harness and confirming it now decodes back to "トウキョウト".

**Fixed:** `Install.command` telling you to "Press Enter to close this
window" even though pressing Enter doesn't actually close the Terminal
window (that depends on your Terminal profile's "When the shell exits"
setting). Reworded to "Press Enter to finish" so it no longer promises
something it doesn't do.

**Fixed:** Pressing Enter right after certain input could get silently
swallowed instead of submitting the line — most visible as Enter "doing
nothing" after typing Japanese, or two separate messages ending up
concatenated into one.

The multi-byte assembly added for the "◆" fix below reads N more bytes after
a lead byte, trusting that a multi-byte UTF-8 lead byte is always followed by
real continuation bytes, without checking that they actually look like
continuation bytes (`10xxxxxx`). On the real iBook, some byte in the actual
input stream apparently isn't valid UTF-8 the way this code expected, so
whatever came right after it — including a literal Enter keypress — got
consumed as if it were part of that character instead of being handled as
its own keystroke. Reproduced exactly with a pty test: sending a fake 3-byte
lead byte followed by Enter, the old code swallowed the Enter entirely and
only reacted on a *second* Enter, having merged the first one into the
buffer as raw bytes. Fixed by validating each continuation byte and pushing
it back to be read again as its own keystroke when it isn't one — so Enter
(or any other key) can no longer disappear into a bad assembly.

**Fixed:** Typing at the prompt (any character, not just Japanese) no longer
pushes the terminal down one new line per keystroke instead of editing in
place.

The line editor's redraw closure reprinted the *entire* prompt string on
every keystroke to redraw the line — and that prompt string is
`"\nご用件をどうぞ> "`, with a **literal leading newline** baked in (it's meant
to print once, to leave a blank line before the prompt). Redrawing it after
every single character sent that newline to the terminal again each time,
so the "line" being edited kept advancing instead of being overwritten in
place — confirmed with a pty test: redraw count scaled exactly 1:1 with
characters typed (20 characters in → 20 extra newlines out) regardless of
whether the characters were ASCII or Japanese, which is what ruled out the
UTF-8 decode fix below as the sole cause. An initial attempt at this fix
suspected the terminal's output post-processing (`opost`/`ocrnl` turning an
outgoing `\r` into a newline) and disabled `opost`, but that changed nothing
on real hardware — the actual bug was this project's own code re-sending the
prompt's leading newline on every redraw. Fixed by stripping the leading
newline from the prompt text used for per-keystroke redraws, so only the
very first print of the prompt includes it.

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

### 2026-08-28

**追加:** Anthropicに加えて、Gemini(Google)にも対応しました。`setup.sh`で最初に
どちらを使うか聞かれます。Geminiの無料枠はクレジットカードが一切不要で、
MacRumorsのPowerPC Macs板でのこのプロジェクトへの反応を見る限り、これが
「面白そうだけど試すには至らない」の一番の壁になっていたようです。

内部的には、会話履歴はプロバイダに関わらず常にAnthropic形式で保持していて、
API呼び出しの直前・直後だけGeminiの`contents`/`parts`/`functionCall`形式に
変換しています。なので、このファイルの大部分を占めるターミナル入力処理や
ツール実行のコードは一切変更不要でした。

**実機で見つけて修正:** Gemini 3は、`functionCall`に付いてくる不透明な
`thoughtSignature`を、次のターンで同じパーツにそのまま付け直して送り返さないと
400エラーになります。Gemini 2.5までは任意でしたが、3系では必須の検証に
変わっていました。実際のiBookで、複数回のツール呼び出し(`list_dir` →
`run_shell` → `run_shell` → `list_dir`)が2回目のツール呼び出しで失敗する形で
発覚しました。

**修正:** APIレスポンスの読み込みで、日本語(などマルチバイト文字)が
`utf8 "\xXX" does not map to Unicode`という警告と共に化けることがある不具合。
以前STDIN読み込みで直したのと全く同じ、PerlIO `:encoding(UTF-8)`のバッファ
境界バグが、今回はレスポンス読み込み側で出ていました。`run_shell`の結果に
`ダウンロード`というフォルダ名が含まれていたことで発覚。直し方も同じで、
生バイトで読んでから最後にまとめてデコードするようにしました。

**変更:** コマンド名を`claude`から`advisor`に変更しました。Geminiと話してるのに
`claude`と打つのは、確実に「あれ、これ本当に合ってる?」となる瞬間だったので。
このプロジェクトはそもそも特定の会社のAIが主役なんじゃなくて、古いマシンに
「何かに答えてくれる相手」を持たせることが目的だったので、どのAIが答えるかは
コマンド名から消しました。

**追加:** 会話中に`/claude`または`/gemini`と打つと、その場でプロバイダを
切り替えられます(会話はそのまま引き継がれます)。切り替え先のキーがまだ
無い場合は、その場でパスワード欄のように画面に表示せず入力を求められます —
Escか Ctrl+Cで、何も変えずにきれいに取り消せます。

**修正:** Geminiへのリクエストが不必要に遅かった不具合。実機のiBookで
「ビールの主成分は?」という単純な質問に約30秒かかっていました。Gemini 3系の
モデルはリクエストで`thinkingLevel`(内部でどれだけ深く考えるか)を指定しないと
既定で"HIGH"(最大限考える)になりますが、このコードはどこでもそれを指定して
いませんでした。気軽な質問には素早く答えられるよう既定を"LOW"にし、じっくり
考えてほしい時のために`CLAUDE_GEMINI_THINKING=high`で元の挙動に戻せるように
しました(Gemini 2.5系は`thinkingLevel`が無いので、代わりに`thinkingBudget`で
同等の設定をします)。`setup.sh`と`Install.command`の疎通確認にも同じ問題が
あったため、同じ修正を適用しています。

**修正:** ダブルクリック用インストーラー(`Install.command`。配布用zipに入って
いる方)が、まだAnthropicしか知りませんでした — Gemini対応の選択肢は、ソース
からビルドする手順用の`setup.sh`にしか入っていませんでした。「Anthropicか
Geminiか」を最初に聞く同じ流れを`Install.command`にも移植し、インストールされる
コマンド名も`claude`から`advisor`に合わせて変更しました。zip内の`README.txt`も
合わせて更新しています。

**変更:** Geminiの既定モデルを`gemini-3.6-flash`から`gemini-3.5-flash-lite`に
変更しました。実機のiBookで判明したのですが、`gemini-3.6-flash`の無料枠は
**1日20リクエストまで**で、インストール確認とテストだけであっさり使い切って
しまいました。`flash-lite`系のモデルは無料枠の1日あたり上限がずっと大きいです。
日常の雑談程度なら最新モデルである必要はなく、本格的な分析やビジネス用途が
必要な方は最新のMacやWindowsを使ってもらう、という前提での判断です。
以前のモデルに戻したい場合は`CLAUDE_MODEL`で上書きできます。

**修正:** 「このサイトを要約して」のようにURL取得を頼むと、`run_shell`の試行が
5回も必要になり、その都度y/Nの確認が挟まって画面が賑やかになっていた不具合。
システム標準の`curl`はTLS 1.2に対応しておらずHTTPSを一切扱えず、しかもモデルは
Tigerの古いPython 2に対してPython 3の書き方(`urllib.request`や
`except X as e:`)を何度も試して失敗していました。実はTLS対応のcurlは
`advisor`ラッパースクリプトが設定する`$CLAUDE_CURL`(と`$CLAUDE_CACERT`)という
環境変数経由で`run_shell`の子プロセスにもすでに渡っていたのですが、
システムプロンプトにその存在を書いていませんでした。この2点(HTTPSには
`$CLAUDE_CURL`を使うこと、Pythonは古い2系である前提で書くこと)を一言
書き加えることで、最初の1回で正しい方法を選べるようにしました。

### 2026-08-22

**修正:** ターミナルの横幅を超えて折り返すくらい長い行を入力すると、同じ行が
画面いっぱいに何度も表示されてしまう不具合。文字入力・Backspace・矢印キーでの
編集・↑↓での履歴呼び出しのどれをやっても、折り返した行がクリアされずに
どんどん積み重なっていました。実機のiBookで、同じプロンプトがずらっと並んだ
スクリーンショットから発覚。行編集の再描画処理は「今いる1行だけをクリアして
再表示」という作りで、入力が複数行に折り返した瞬間、最後の行しかクリアできて
おらず、それより上の行(前回の再描画分)がそのまま残ってしまっていました。
前回の再描画で使った行数を記録し、その先頭行までカーソルを戻してから画面末尾
までをまとめてクリアするよう修正。ptyと仮想端末レンダラーを使い、折り返す
長文入力・Backspace・左右矢印・短い/長い履歴の↑↓呼び出しで、いずれも重複
なく描画されることを確認済みです。

**修正:** ここまでの一連の修正を経てもなお、日本語(や、恐らく他のIME経由の
入力)が文字化けしていた根本原因。実機のTerminal.appは、IMEで確定した
テキストを渡すとき、各バイトの前に文字通り`0x16`(Ctrl-V。Unix系端末で
伝統的に「次の1文字をそのまま扱え(LNEXT)」という合図に使われてきたバイト)
を付けて送ってきていました。この行編集機能は端末をraw modeにして自前で
入力を読んでおり、このLNEXTの合図を解釈していなかったため、`0x16`がゴミ
バイトとしてそのままバッファに混入し、UTF-8を壊していました。行編集機能に
一時的なデバッグログ機能(`CLAUDE_DEBUG_INPUT=パス claude`)を追加し、
実機で実際に届いたバイト列を記録してもらったところ判明しました:「トウキョウ
ト」と入力すると`16 e3 16 83 16 88 16 e3 16 82 16 a6 ...`という列が届いて
おり、`16`を全部取り除いた`e3 83 88 e3 82 a6 ...`は、まさに「トウキョウト」
を表す完全に正しいUTF-8でした。IME経由でなく直接タイプした半角英数字には
`0x16`が一切付いていなかったことも確認でき、これが日本語入力だけで起きて
いた理由も説明できました。行編集機能が`0x16`を読み飛ばし、その次のバイトを
本来のデータとして扱うように修正し、実機で記録された、このバイト列そのもの
をテストに使って「トウキョウト」に正しくデコードされることを確認しました。

**修正:** `Install.command`が「Enterキーで閉じます」と表示するのに、実際には
Enterを押してもターミナルのウィンドウ自体は閉じない(閉じるかどうかは
Terminalのプロファイル設定の「シェルの終了時」の項目次第)という不一致。
「Enterキーで完了します」という、実態に合った表現に変更しました。

**修正:** 特定の入力の直後にEnterを押しても、行が送信されずに黙って
飲み込まれてしまうことがある不具合。日本語を入力した直後にEnterを押しても
「何も起きない」ように見えたり、本来別々に送るはずだった2つのメッセージが
1つに繋がって送信されてしまったりする形で現れていました。

下記の「◆」化け修正で追加した、マルチバイト文字の続きバイトを読み込む処理は、
マルチバイトUTF-8の先頭バイトの後には必ず本物のcontinuationバイト
(`10xxxxxx`形式)が続くと決めつけて、その形式かどうかを確認せずにN バイト
読み込んでいました。実機では、実際の入力ストリームのどこかにこのコードが
想定していた形のUTF-8ではないバイトが混ざっているらしく、その直後に来た
もの――**Enterキーの押下も含めて**――が、本来の1回のキー入力としてではなく、
その(偽の)マルチバイト文字の一部として飲み込まれてしまっていました。pty
テストで正確に再現できました: 偽の3バイト文字の先頭バイトの直後にEnterを
送ると、旧コードはそのEnterを丸ごと飲み込んでしまい、次にもう一度Enterを
送って初めて反応し、最初のEnterは生バイトとしてバッファに混ざったまま
残っていました。続きバイトが本当にcontinuationバイトの形式かどうかを検証し、
そうでなければ読み戻して改めて1つのキー入力として処理し直すように修正した
ことで、Enter(に限らずどんなキーでも)が不正なバイト組み立ての中に消えて
しまうことがないようにしました。

行編集機能の再描画処理は、1キー入力するたびにプロンプト文字列を**まるごと**
再出力して行を描き直していました。ところがそのプロンプト文字列は
`"\nご用件をどうぞ> "`と、**先頭に改行文字を含んで**いました(プロンプトの前に
空行を1つ入れるための改行で、本来は最初の1回だけ出せば良いもの)。これを
キー入力のたびに毎回再出力していたため、1文字打つごとに本物の改行が
ターミナルに送られ続け、編集中の行がその場で上書きされず、どんどん次の行に
進んでいってしまっていました。ptyを使ったテストで、再描画のたびに送られる
改行の数が入力した文字数と正確に1対1で比例すること(20文字入力→改行20個
増加)を確認して原因を特定しました。しかも英数字でも日本語でも同じように
起きることから、下記のマルチバイトデコードの修正だけが原因ではないと
判明しました。最初はターミナルの出力後処理(`opost`/`ocrnl`が出力の`\r`を
改行に変換してしまう)を疑って`opost`を無効化しましたが、実機で試しても
何も変わらず、実際の原因はこのプロジェクト自身のコードがプロンプトの
先頭改行を再描画のたびに送り直していたことでした。再描画に使うプロンプト
文字列から先頭の改行を取り除き、最初の1回の表示でだけ改行を出すように
修正しました。

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
