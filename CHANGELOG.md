# Changelog

**[English](#english) | [日本語](#japanese)**

<a id="english"></a>
## English

This file is not just a technical log — it's also where I want to say thanks to
whoever actually ran this thing on real hardware and noticed something was off.
If that's you, thank you.

### 2026-09-08

**Investigated:** A report from real PowerBook G4 hardware describing text appearing "in
the wrong place" while editing - retyped characters landing somewhere unrelated, and lines
that seemed to corrupt themselves. Captured a `CLAUDE_DEBUG_INPUT` byte-level log on the
actual machine and traced every keystroke against the buffer position it produced. Result:
the underlying editing logic was not at fault - every Left/Right arrow press moved the
cursor by exactly one full-width character (3 bytes), with no drift, no skipped bytes, no
double-firing. What happened was that the cursor had been moved several characters left,
then a couple right, landing between two characters that look nearly identical to their
neighbors in a wall of kanji - and new text got typed in right there, producing a sentence
that reads as garbled even though nothing was lost or duplicated. In other words: the
program tracked the cursor correctly the whole time, but the *person* editing lost track of
where it was, because the only indicator of cursor position was the terminal's native
blinking cursor - easy to lose on an old, dim, or small display, especially with dense
full-width text.

**Fixed:** Rather than the data itself, fixed the thing that actually caused the confusion:
when the cursor is not at the end of the line, everything after it is now printed in
reverse video (standard ANSI `SGR 7`, supported since basically every VT100-compatible
terminal, including Mac OS X 10.4's Terminal.app). This makes "what's after my cursor"
visually unmistakable at a glance, instead of relying on spotting a blinking underline
among a wall of characters. No new keybinding was added - per earlier feedback, editing
should stay usable by the small set of commands people already remember (arrows, Backspace,
Ctrl+C to cancel the line), not grow a new one to work around a visibility problem. Verified
the exact byte sequence sent to the terminal with a pty test (confirmed only the intended
tail bytes get wrapped in `\x1b[7m...\x1b[0m`. and the cursor-position math is untouched),
and reran the full existing regression suite (wrapping input, multi-row Left-arrow, arrow
races, Backspace, zero-size stty) with no change in behavior beyond the added highlighting.

### 2026-09-08 (yet one more)

**Fixed:** Found the real cause of the "same question appears as 2-3 duplicate lines"
reports, by replaying a real debug log's recorded escape sequences through a virtual
terminal to see exactly what the user saw. It traced back to the lazy-headroom fix itself
(from earlier today): when a growing line was about to reach the terminal's bottom row,
the code printed the needed blank lines and *assumed* that always caused a real scroll -
shifting every row's numbering up, including the input block's own start row, which it then
adjusted for by arithmetic. But if the cursor wasn't already sitting at the very last row
when those blank lines were sent (e.g. there was still exactly one free row below), printing
them just used up that free row - no scroll happened - yet the code adjusted its bookkeeping
as if one had. The next redraw then moved to "the block's start" one row short of where the
actual content was, erased and reprinted only part of it, and left the old row behind -
which a moment later got scrolled away for real, permanently baking in a duplicate.

Fixed by no longer assuming: after sending the blank lines, move the cursor back (by a pure
relative Cursor Up, which is correct whether or not a scroll actually happened) to where the
block's start should be, and ask the terminal directly via CPR what row that actually is.
Falls back to the old arithmetic only if CPR doesn't answer. Reproduced with a pty test that
places a growing line so it hits the terminal's exact last row from various amounts of
slack (0 and 1 free rows below) - confirmed the pre-fix code duplicates a line in both cases,
confirmed today's fix is clean in both, and reran the full existing regression suite.

Deployed to all three machines and repackaged the release zip.

### 2026-09-08 (one more)

**Fixed:** A PowerBook G4 transcript showed something that looked, at first glance, like
another terminal rendering bug: a run of lines each one character longer than the last -
"クリ", "クリー", "クリーム", "クリームと"... - stacking up between two `claude>` replies.
It wasn't a rendering bug at all. Gemini's thinking feature returns its intermediate
reasoning as its own "thought" parts in the response, separate from the final answer, each
marked with a `thought: true` flag - and the response parser was pulling in *every* part
that had a `text` field, thinking parts included, and displaying all of them as if they were
the final reply. The model's out-loud reasoning ("cream... no, cream and tea...") was being
shown verbatim as consecutive lines of output. Fixed by skipping any part marked
`thought: true` before collecting text - confirmed with a unit test feeding a mix of thought
and final-answer parts through the parser, verifying only the real answer survives.

Deployed to all three machines and repackaged the release zip.

### 2026-09-08 (later still)

**Fixed:** Turning debug logging on persistently (so it no longer needs a special command to
enable) paid off almost immediately: a log covering a session with real editing - Backspace,
arrow keys, inserting text mid-line - showed things going badly wrong near the end, matching
the report exactly ("chaos" after going back and adding text). Found the smoking gun:

```
[probe] initial pos: row=32 col=1
[probe] after CUP 500;500: max_row=32 max_col=1
[probe] using measured size: 32x1 (stty said 32x59)
```

Yesterday's terminal-size probe measured a **1-column-wide** terminal - obviously wrong,
since `stty size` (correctly, on this run) said 59. With `$term_cols` at 1, the line editor
believed every single character needed its own row, and started inserting a newline for
essentially every keystroke - which is exactly what "chaos" looks like from the user's side:
the banner and everything above scrolls away within a few characters. Root cause: two prompts
starting back-to-back in quick succession (e.g. right after an accidental blank Enter) can
let one prompt's CPR response arrive late and get read by the *next* prompt's probe instead -
the strict grammar check still accepts it (it's a well-formed `ESC [ row ; col R`, just for
the wrong query), so a stale or mismatched reply slips through as if it were the real answer.
Timeout-and-pushback protects against a response that never comes or comes back malformed; it
doesn't protect against one that arrives, is well-formed, but is answering the wrong question.

Rather than trying to eliminate that race entirely (would need matching queries to responses,
which real terminals have no way to do), added a plausibility floor: no real terminal is ever
1 column wide, so a measured size under an obviously-impossible threshold (3 rows / 10 columns)
is now treated the same as a failed measurement and discarded in favor of `stty size` - which,
per today's earlier finding, might itself occasionally be wrong, but is never as catastrophically
wrong as "1 column". This bounds the worst case to "no worse than before yesterday's fix" while
keeping the fix's benefit for the common case.

Reproduced with a pty test that injects a deliberately bogus `1;1R` reply to the size-probe
query: confirmed the pre-fix code loses the banner off-screen within a handful of keystrokes,
confirmed today's fix falls back cleanly to `stty size` and types normally. Full existing
regression suite still passes.

Deployed to g4 and pbg4 (ibook offline at the time).

### 2026-09-08 (later)

**Fixed:** The PowerBook G4 test above turned up a second, more serious bug behind the
same report: a fresh `CLAUDE_DEBUG_INPUT` log, and a screenshot, showed the exact old
"growing duplicate lines in scrollback" pattern again, even with yesterday's lazy-headroom
fix in place and working correctly on other machines. Root cause: that fix decides when to
insert protective newlines by comparing the real cursor row (from CPR, trustworthy) against
`$term_rows` from `stty size` - and on this particular machine, `stty size` was reporting a
row count noticeably *smaller* than the terminal's actual height (this is a different fault
than the earlier "returns 0 0" PowerMac G4 quirk - this one returns a plausible but wrong
non-zero number). That made the code think it was near the bottom of the screen far earlier
than it actually was, triggering the newline-insertion path way too soon and producing
exactly this symptom. Reproduced deterministically with a pty test that fakes a small
`stty size` while giving the terminal itself much more real room, confirmed it reproduces
the bug against yesterday's code, and confirmed today's fix below resolves it.

Fixed by no longer trusting `stty size` for the row count when CPR is available: move the
cursor to a deliberately out-of-range position (row/col 9999), query where the terminal
actually clamped it to via CPR, and use that as the true screen height (and width), then
move the cursor back. This piggybacks on the same CPR round-trip already being used for the
scrollback fix, so it costs nothing extra beyond what today's earlier fix already pays -
once per prompt, not per keystroke - and falls back to `stty size` exactly as before on any
terminal that doesn't answer CPR at all. Verified with the new pty test (reproduces the bug
against yesterday's code, passes clean against today's) and the full existing regression
suite.

Deployed to all three machines (ibook, g4, pbg4) and repackaged the release zip.

### 2026-09-08

**Investigated:** A report from real PowerBook G4 hardware describing text appearing "in
the wrong place" while editing - retyped characters landing somewhere unrelated, and lines
that seemed to corrupt themselves. Captured a `CLAUDE_DEBUG_INPUT` byte-level log on the
actual machine and traced every keystroke against the buffer position it produced. Result:
the underlying editing logic was not at fault - every Left/Right arrow press moved the
cursor by exactly one full-width character (3 bytes), with no drift, no skipped bytes, no
double-firing. What happened was that the cursor had been moved several characters left,
then a couple right, landing between two characters that look nearly identical to their
neighbors in a wall of kanji - and new text got typed in right there, producing a sentence
that reads as garbled even though nothing was lost or duplicated. In other words: the
program tracked the cursor correctly the whole time, but the *person* editing lost track of
where it was, because the only indicator of cursor position was the terminal's native
blinking cursor - easy to lose on an old, dim, or small display, especially with dense
full-width text.

**Fixed:** Rather than the data itself, fixed the thing that actually caused the confusion:
when the cursor is not at the end of the line, everything after it is now printed in
reverse video (standard ANSI `SGR 7`, supported since basically every VT100-compatible
terminal, including Mac OS X 10.4's Terminal.app). This makes "what's after my cursor"
visually unmistakable at a glance, instead of relying on spotting a blinking underline
among a wall of characters. No new keybinding was added - per earlier feedback, editing
should stay usable by the small set of commands people already remember (arrows, Backspace,
Ctrl+C to cancel the line), not grow a new one to work around a visibility problem. Verified
the exact byte sequence sent to the terminal with a pty test (confirmed only the intended
tail bytes get wrapped in `\x1b[7m...\x1b[0m`. and the cursor-position math is untouched),
and reran the full existing regression suite (wrapping input, multi-row Left-arrow, arrow
races, Backspace, zero-size stty) with no change in behavior beyond the added highlighting.

### 2026-09-07

**Changed:** Yesterday's scrollback fix reserved headroom unconditionally at the start of
every prompt, which worked, but left a large permanent blank gap in scrollback history
above the very first prompt — paid even for short replies ("y", "exit") that were never
going to need the room. Made it lazy instead: the terminal's cursor row is still queried
once via CPR at the start, but no padding is printed until a specific redraw is actually
about to reach the bottom of the terminal, and then only exactly enough to clear it. Same
CPR query as before (no extra cost), just deferred to the moment it's actually needed -
ordinary short messages now print no padding at all.

**Fixed:** While reasoning through the above, found a real, separate, pre-existing bug:
moving the cursor left across a *row* boundary (not just a column) with the arrow key -
e.g. typing several wrapped lines and then pressing Left enough times to land on an earlier
row - and then editing there could wipe out everything above the prompt, including the
conversation history, on the very next redraw. The redraw's "move cursor back to the top of
the block" step always moved up by the block's full height, silently assuming the cursor
was sitting at the bottom row - true right after typing, but no longer true once Left/Right
had repositioned it via CHA to an earlier row. The resulting overshoot moved past the top of
the block and erased whatever was above it. Confirmed with a pty test: type three wrapped
lines, press Left 25 times to reach the first line, edit there - the banner above the
prompt vanished on the very next keystroke. Fixed by tracking where the cursor actually
ended up after each redraw (natural end vs. an earlier row via CHA) and using that instead
of the block's full height when deciding how far to move up on the next one. This was
present before today's changes; it just hadn't been exercised by the redraw tests until
this specific multi-row-Left scenario was tried. Verified: the same pty test now leaves the
banner intact, and the full existing regression suite (wrapping input, Backspace, arrow
keys, CPR races) still passes.

Deployed to the machines that were reachable (g4 and pbg4 were offline at the time; ibook
updated) and repackaged the release zip.

### 2026-09-06

**Fixed:** Scrolling up in the terminal's history could reveal dozens of near-duplicate
lines — one more character than the last — from earlier in the same conversation, looking
exactly like a bug even though the live screen and the conversation itself were correct the
whole time. Cause: the line editor clears and reprints on every keystroke, but ANSI's
"clear screen" only reaches what's currently visible — once a keystroke's redraw is tall
enough to push the terminal into scrolling (because the prompt started too close to the
bottom), whatever scrolled off the top is gone for good, permanently recording that
in-progress, soon-to-be-replaced state in history. Every further keystroke that grows the
line past another row boundary repeats this, leaving a trail of growing snapshots that
never gets erased. Fixed by querying the terminal's actual cursor row before accepting
input (via the standard VT100 Cursor Position Report, `\x1b[6n`) and, if there isn't much
room left below, printing enough blank lines up front to reach safer ground - so ordinary
messages no longer trigger a scroll mid-edit in the first place. Times out safely (0.3s) on
terminals that don't answer, falling back to the old behavior with no regression. Found,
while investigating this, that the CPR wait could itself race with the user typing
immediately afterward and swallow their first keystroke - fixed by validating the response
byte-by-byte against the exact CPR grammar and pushing back everything read the moment it
stops matching, so real input (arrow keys included, despite sharing CPR's `ESC [` prefix)
is never mistaken for a stale reply.

### 2026-09-05

**Fixed:** Typing Japanese (or any full-width/double-byte) text at the prompt could
progressively corrupt the display — text appearing several characters behind the cursor,
parts of the static banner above the prompt getting overwritten, everything getting worse
the longer you typed. A debug capture of the raw input bytes (`CLAUDE_DEBUG_INPUT`) showed
the *data* being received was completely correct the whole time — this was a pure display
bug in the redraw math, not an input-decoding one. The line editor's row/column
calculations derived a character's screen position from a single aggregate "total display
width" divided by the terminal's column count, silently assuming cells always pack
perfectly. Real terminals don't do that for full-width characters: if only one cell is
left in a row and the next character needs two, the terminal pushes that whole character
to the next row rather than splitting it, leaving the last cell of the row blank. Every
time that happened, the aggregate-width math and the terminal's actual cursor position
drifted apart by one cell — and since redraws happen on every keystroke, that drift
compounded into exactly the escalating corruption described above. Fixed by walking the
text one character at a time to compute cursor position, exactly mirroring how a real
terminal decides whether a wide character fits in the remaining space on a row.

**Fixed:** On a real PowerMac G4 (Mac OS X 10.4.0, build 8A428), moving the cursor left
with the arrow keys and then pressing Backspace deleted the wrong character — several
positions away from where the cursor visually appeared, sometimes leaving the character you
actually wanted to delete untouched. Tracked down over SSH to the real machine: `stty size`
there reports `0 0` even in a perfectly normal terminal window, and the line editor's
`_term_width` helper treated that `0` as a legitimate column count instead of an invalid
reading, which made every cursor-repositioning calculation collapse to "column 0" — so
after any Left/Right arrow move, the redraw always snapped the visual cursor back to the
very start of the line while the actual edit position (tracked separately, correctly) was
wherever it should be. Backspace itself was never wrong; the cursor you were looking at was
just lying about where it was. Fixed by rejecting `0` as a column count and falling back to
80, same as an unparseable `stty size` already did. Reproduced and confirmed fixed with a
pty forced to a 0x0 window size, matching the real machine's behavior exactly.

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

### 2026-09-08

**調査:** 実機のPowerBook G4から、編集中に文字が「関係ないところに入る」、行が
勝手に壊れる、という報告をいただきました。実機で`CLAUDE_DEBUG_INPUT`のバイト
レベルのログを取得し、キー入力1回1回をバッファ上の位置まで全部突き合わせて
追跡しました。結果: 編集ロジック自体には問題がありませんでした。左右矢印キーを
押すたびに、カーソルは全角1文字分(3バイト)ぴったり正確に動いており、ズレも、
バイトの取りこぼしも、二重発火もありませんでした。実際に起きていたのは、左矢印で
数文字分カーソルを戻した後、右矢印で2文字分だけ戻し過ぎを直した結果、漢字が
並ぶ中でほとんど見分けのつかない2文字の間にカーソルが止まっており、そこに新しい
文章を打ち込んでしまっていた、ということでした。文字は一切失われても重複しても
おらず、ただ「挿入された場所」が意図と違っていたために、文として壊れて見えて
いました。つまり、プログラムはカーソル位置を最初から最後まで正確に把握して
いましたが、**操作している本人がカーソルの位置を見失っていた** ということです。
原因は、カーソル位置を示すものが端末標準の点滅カーソルしかなく、古い/小さい/
暗めの画面で、しかも漢字がぎっしり並んだ画面の中では非常に見づらいことでした。

**修正:** データそのものではなく、混乱の原因になっていた「見えにくさ」の方を
直しました。カーソルが行の途中にある時、カーソルより後ろの文字列をすべて反転
表示(標準ANSIの`SGR 7`。VT100互換端末ならほぼ必ず対応しており、Mac OS X 10.4の
Terminal.appでも問題なく表示できます)にするようにしました。これで「カーソルの
後ろに何があるか」が、点滅する下線を文字の海から探すのではなく、一目で分かる
ようになります。新しいキー操作は追加していません — 以前いただいたご指摘の
とおり、編集操作はすでに覚えている少数のコマンド(矢印キー・Backspace・行を
まっさらにするCtrl+C)だけで完結すべきで、見えにくさを補うために新しいコマンドを
増やすべきではないからです。実際に端末へ送られる生のバイト列をptyテストで
確認し(意図した「カーソルより後ろ」の部分だけが`\x1b[7m...\x1b[0m`で囲まれ、
カーソル位置計算そのものには一切手を入れていないことを確認済み)、既存の回帰
テスト一式(折り返す入力・複数行にまたがる左矢印・矢印キーとの競合・Backspace・
`stty size`が0 0を返す環境)もすべて、反転表示が加わった以外は変化なく通ることを
確認しています。

### 2026-09-08(さらにもう一件)

**修正:** 「同じ質問が2〜3行に重複する」という報告の本当の原因を、実機のデバッグ
ログに記録された送信内容を仮想端末に実際に流し込んで再現することで特定しました。
原因は今日前半に入れた「遅延ヘッドルーム」の対策自体にありました: 伸びていく行が
画面の最下段に達しそうになった時、必要な分だけ改行を送るのですが、そのコードは
「改行を送った=必ず本当にスクロールが起きて、入力ブロックの開始行を含む全ての
行番号が1つずつ若くなったはず」と決め打ちして、その分を計算で補正していました。
しかし、改行を送った瞬間にカーソルがまだ画面の本当の最下段にいなかった場合
(例えば、あと1行だけ余裕が残っていた場合)、その改行はただその余った1行を
使うだけでスクロールは起きません。それなのにコードは「スクロールした」前提で
補正してしまい、次の再描画が本来の位置より1行ズレた場所で「ブロックの先頭」と
誤認識してしまいます。結果、古い行を消しきれずに新しい行をその下に重ねて
印字してしまい、少し後で本当にスクロールが起きた時に、その古い行がそのまま
スクロールバックに焼き付いて重複して見える、という仕組みでした。

「必ずこうなるはず」という決め打ちをやめ、改行を送った後に相対的なカーソル上移動
(スクロールが起きていてもいなくても正しく効く)でブロックの先頭に戻り、そこで
改めてCPRで「今本当は何行目にいるか」を端末に直接尋ねるように直しました。CPRに
応答がない環境でのみ、従来通りの計算に頼ります。伸びていく行がちょうど画面の
最下段に達する状況を、余裕0行・1行の両方でわざと作るptyテストを書いて、修正前の
コードでは両方とも重複が再現し、修正後はどちらもきれいに直ることを確認し、既存の
回帰テスト一式も全て通ることを確認しました。

3台すべてに配布し、配布用zipも作り直しました。

### 2026-09-08(もう一件)

**修正:** PowerBook G4のログに、一見また別のターミナル描画バグに見えるものが
映っていました — 「クリ」「クリー」「クリーム」「クリームと」…と1文字ずつ
伸びていく行が、`claude>`の返答の間に何行も積み重なっている、というものです。
これは実は描画のバグではありませんでした。Geminiの「思考」機能は、最終回答とは
別に、途中の考えの過程を`thought: true`という印が付いた別のpartとして返して
くることがあるのですが、応答を解析する側が`text`フィールドを持つpartを
**全部まとめて**拾ってしまっていて、思考の途中経過もそのまま最終回答と同じ
ように画面に出してしまっていました。モデルが心の中で「クリーム…いや、
クリームと紅茶かな…」と考えている過程が、そのまま連続した行として画面に
出ていた、ということです。`thought: true`が付いているpartは拾う前に読み飛ばす
ように修正し、思考パートと最終回答パートが混在した応答を模したユニット
テストで、最終回答だけが残ることを確認しました。

3台すべてに配布し、配布用zipも作り直しました。

### 2026-09-08(続報その2)

**修正:** デバッグログを「毎回自動で残る」設定に変えた効果がすぐに出ました。実際に
Backspace・矢印キー・行の途中への挿入をした実機セッションのログに、報告いただいた
「戻ったり後から付け足すとカオス」とぴったり一致する崩れ方が記録されていました。
決定的な証拠がこれです:

```
[probe] initial pos: row=32 col=1
[probe] after CUP 500;500: max_row=32 max_col=1
[probe] using measured size: 32x1 (stty said 32x59)
```

昨日入れたばかりの「端末サイズの実測」が、**桁数1**というありえない値を掴んで
しまっていました。この時`stty size`は(今回は)正しく59と答えていたので、
明らかにこちらの実測の方がおかしいです。`$term_cols`が1になると、行編集ロジックは
「1文字ごとに次の行へ折り返さなければいけない」と思い込み、ほぼ1文字打つたびに
改行を挿入し始めます。ユーザー側から見れば、数文字打っただけでバナーごと画面の
上の方が全部スクロールして消えていく「カオス」そのものです。原因: 2つのプロンプトが
間を置かずに立て続けに始まる(例えば誤って空Enterを押した直後など)と、片方の
プロンプトへのCPR応答が遅れて届き、**次のプロンプトの実測処理がそれを読んでしまう**
ことがあります。文法チェック自体は(`ESC [ 行 ; 桁 R`という正しい形にはなっている
ので)通ってしまい、「別の質問への回答」を「今回の質問への回答」として誤って
受け取ってしまいます。タイムアウト+読み戻しの仕組みは「応答が来ない」「応答が
壊れている」場合は守ってくれますが、「応答は来ているし形も正しいが、答える相手を
間違えている」場合までは守ってくれません。

このレースコンディション自体を完全になくすのは(応答がどの質問に対するものかを
突き合わせる仕組みが、実在する端末側には無いため)難しいので、代わりに「明らかに
おかしい値は捨てる」という下限チェックを入れました。現実のどんな端末も桁数1という
ことはまずあり得ないので、実測結果が明らかにあり得ない範囲(3行未満・10桁未満)
だった場合は「実測失敗」と同じ扱いにして`stty size`にフォールバックするようにし
ました。`stty size`自体、今日の前半で見つけた通りズレることもありますが、「桁数1」
ほど致命的にズレることはまずないため、最悪でも「昨日の修正より前の状態と同程度」に
とどめつつ、通常時は今日の修正の恩恵をそのまま受けられます。

わざと壊れた`1;1R`という応答を実測処理に返すptyテストで再現し、この安全策を
入れる前のコードでは数文字打っただけでバナーごと画面外に消えること、修正後は
`stty size`へきれいにフォールバックして正常に入力できることの両方を確認しました。
既存の回帰テスト一式もすべて通ることを確認済みです。

g4とpbg4に配布しました(ibookはこの時点でオフラインでした)。

### 2026-09-08(続報)

**修正:** 上のPowerBook G4での調査から、同じ報告の裏にもう一つ、より深刻な不具合が
見つかりました。実機で改めて取得した`CLAUDE_DEBUG_INPUT`ログとスクリーンショットに、
昨日直したはずの「スクロールバックに行が何度も積み重なって見える」現象が、他の
マシンでは問題なく効いている昨日の遅延ヘッドルーム対策込みでもまだ再現していました。
原因: あの対策は「画面の下端に近いか」を、CPRで得た信頼できる実際のカーソル行と、
`stty size`から得た`$term_rows`を比べて判定していますが、このマシンでは`stty size`が
実際のウィンドウの高さより明らかに小さい行数を返していました(以前PowerMac G4で
見つかった「0 0を返す」不具合とは別物で、今回はゼロではなく、もっともらしいが
間違った行数を返すパターンです)。これにより、実際にはまだ全然余裕があるのに
「もう画面の下端だ」と誤判定し、改行挿入処理が早すぎるタイミングで発火し、まさに
この症状を生んでいました。`stty size`だけ小さい値を返すよう偽装しつつ実際の端末
には十分な余裕を持たせるptyテストを書いて確定的に再現させ、昨日のコードに対しては
実際に再現すること、今日の修正で解消することの両方を確認しました。

対策として、CPRが使える環境では行数の判定に`stty size`をもう信用しないことにし
ました: わざと画面の外側(行・列とも9999)へカーソルを動かしてから、CPRで実際に
どこにクランプされたかを問い合わせることで、本当の画面の高さ・幅を直接測定し、
その後カーソルを元の位置へ戻します。これは今日の前半の修正で既に使っているCPRの
やり取りに便乗させているので、追加のコストは(1打鍵ごとではなく1プロンプトごと、
という既存の方針のまま)発生しません。CPRに一切応答しない端末では、今まで通り
`stty size`にフォールバックします。新しいptyテスト(昨日のコードに対しては再現し、
今日の修正済みコードに対しては再現しないことを確認済み)と、既存の回帰テスト
一式の両方で確認済みです。

3台すべて(ibook・g4・pbg4)に配布し、配布用zipも作り直しました。

### 2026-09-08

**調査:** 実機のPowerBook G4から、編集中に文字が「関係ないところに入る」、行が
勝手に壊れる、という報告をいただきました。実機で`CLAUDE_DEBUG_INPUT`のバイト
レベルのログを取得し、キー入力1回1回をバッファ上の位置まで全部突き合わせて
追跡しました。結果: 編集ロジック自体には問題がありませんでした。左右矢印キーを
押すたびに、カーソルは全角1文字分(3バイト)ぴったり正確に動いており、ズレも、
バイトの取りこぼしも、二重発火もありませんでした。実際に起きていたのは、左矢印で
数文字分カーソルを戻した後、右矢印で2文字分だけ戻し過ぎを直した結果、漢字が
並ぶ中でほとんど見分けのつかない2文字の間にカーソルが止まっており、そこに新しい
文章を打ち込んでしまっていた、ということでした。文字は一切失われても重複しても
おらず、ただ「挿入された場所」が意図と違っていたために、文として壊れて見えて
いました。つまり、プログラムはカーソル位置を最初から最後まで正確に把握して
いましたが、**操作している本人がカーソルの位置を見失っていた** ということです。
原因は、カーソル位置を示すものが端末標準の点滅カーソルしかなく、古い/小さい/
暗めの画面で、しかも漢字がぎっしり並んだ画面の中では非常に見づらいことでした。

**修正:** データそのものではなく、混乱の原因になっていた「見えにくさ」の方を
直しました。カーソルが行の途中にある時、カーソルより後ろの文字列をすべて反転
表示(標準ANSIの`SGR 7`。VT100互換端末ならほぼ必ず対応しており、Mac OS X 10.4の
Terminal.appでも問題なく表示できます)にするようにしました。これで「カーソルの
後ろに何があるか」が、点滅する下線を文字の海から探すのではなく、一目で分かる
ようになります。新しいキー操作は追加していません — 以前いただいたご指摘の
とおり、編集操作はすでに覚えている少数のコマンド(矢印キー・Backspace・行を
まっさらにするCtrl+C)だけで完結すべきで、見えにくさを補うために新しいコマンドを
増やすべきではないからです。実際に端末へ送られる生のバイト列をptyテストで
確認し(意図した「カーソルより後ろ」の部分だけが`\x1b[7m...\x1b[0m`で囲まれ、
カーソル位置計算そのものには一切手を入れていないことを確認済み)、既存の回帰
テスト一式(折り返す入力・複数行にまたがる左矢印・矢印キーとの競合・Backspace・
`stty size`が0 0を返す環境)もすべて、反転表示が加わった以外は変化なく通ることを
確認しています。

### 2026-09-07

**変更:** 昨日のスクロールバック対策は、プロンプトが始まるたびに無条件で余白を
先回り予約する作りでした。効果はあったのですが、`y`や`exit`のような、そもそも
余白なんて要らない短い返事の時にも毎回律儀に予約してしまい、結果として一番最初の
プロンプトより上に、大きな空白がスクロールバックへ永久に残ってしまっていました。
これを遅延式に変更しました。端末のカーソル行をCPRで問い合わせるのは今まで通り
最初に1回だけですが、改行を差し込むのは「実際にその再描画が画面の下端に届き
そうになった、まさにその瞬間」だけにし、しかもその時に必要な分だけにしました。
CPRの問い合わせ回数は変わらないので、普通の短いメッセージなら余白は一切入り
ません。

**修正:** 上の対応を考えている過程で、今回とは無関係の、以前からあった本物の
不具合を見つけました。矢印キーで(列だけでなく)**行をまたいでカーソルを左に戻す**
と — 例えば折り返した3行分を打った後、左矢印を十分な回数押して最初の行まで
戻ってから編集する、といった操作 — 次の再描画でプロンプトより上にある会話履歴
まで消えてしまうことがありました。再描画の「ブロックの先頭までカーソルを戻す」
処理が、常に「カーソルはブロックの一番下の行にいる」という前提でブロック全体の
高さぶん戻っていたのが原因でした。これは入力し終えた直後は正しいのですが、
左右矢印でカーソルが(CHAで)より上の行に動かされた後はもう成り立ちません。
その結果、戻りすぎてブロックの先頭を通り越し、その上にあったものまで消して
いました。pty上のテストで確認: 折り返す3行を打ち、左矢印を25回押して1行目まで
戻って編集すると、次のキー入力でプロンプトより上のバナーが消えることを再現
できました。修正として、各再描画の後にカーソローが実際にどこに落ち着いたか
(自然な末尾か、CHAで戻された途中の行か)を記録しておき、次の再描画で戻る量には
ブロック全体の高さではなくそちらを使うようにしました。これは今日の変更以前から
存在していた不具合で、この「複数行にまたがる左矢印」という操作パターンをこれまで
のテストがたまたま踏んでいなかっただけでした。同じptyテストでバナーが消えなく
なったことと、既存の回帰テスト一式(折り返す入力・Backspace・矢印キー・CPRとの
競合)がすべて通ることを確認済みです。

到達できたマシンにのみ配布しました(g4とpbg4はこの時点でオフラインだったため、
ibookのみ更新)。配布用zipも作り直しています。

### 2026-09-06

**修正:** ターミナルをスクロールして過去のやり取りを遡ると、同じ会話の中で「1文字だけ
増えた」ほぼ同じ行が何十行も並んで見える不具合。今見えている画面も会話の中身もずっと
正しいのに、パッと見はっきりバグに見えてしまうものでした。原因: 行編集はキー入力の
たびに画面を消して書き直しますが、ANSIの「画面クリア」は今見えている範囲にしか効き
ません。プロンプトが画面の下の方に近い位置で始まっていると、ある1回の再描画が縦に
長くなった瞬間にターミナル自体がスクロールしてしまい、その時に画面の上からはみ出た
「まだ入力途中の、すぐ後で書き換えられるはずだった状態」が、過去ログとして永久に
残ってしまいます。それ以降も1行ぶん増えるたびに同じことが繰り返され、消せないまま
スナップショットが積み重なっていきます。修正としては、入力を受け付ける前に、今の
カーソル行を端末に直接問い合わせ(VT100の頃からある標準機能「CPR」、`\x1b[6n`)、
画面下の余白が少なければあらかじめ改行を足して安全な位置まで進めておくようにしました
。これで、普通の長さのメッセージなら入力の途中でスクロールが起きること自体が無くなり
ます。この問い合わせに応答しない端末でも0.3秒でタイムアウトし、今までの挙動にそのまま
戻るので後退はありません。この対応を作る過程で、CPRの応答待ち中にユーザーが直後に
入力を始めるとタイミングが重なり、最初の1文字を誤って飲み込んでしまう不具合も見つけて
直しました。CPR応答の書式を1バイトずつ厳密に検証し、合わなくなった時点で読んだバイトを
全部押し戻すようにすることで、矢印キー(CPRと同じ`ESC [`から始まるため紛らわしい)を
含め、本物の入力を古い応答と取り違えないようにしています。

### 2026-09-05

**修正:** プロンプトで日本語(や、その他の全角文字)を入力していくと、表示がだんだん
崩れていく不具合。カーソルより数文字分ズレた位置に文字が現れたり、プロンプトより上に
ある固定のバナー部分まで上書きされてしまったりし、入力を続けるほど悪化していきました。
実際に届いている生のバイト列をログに記録する機能(`CLAUDE_DEBUG_INPUT`)で確認したところ、
受け取っているデータ自体はずっと正しく、入力の読み取りではなく再描画時の位置計算だけが
おかしいと分かりました。行編集のカーソル位置計算は、それまで「表示幅の合計を端末の桁数で
割る」という単純な計算をしていて、マス目が常にぴったり詰まる前提になっていました。しかし
実際の端末はそうではなく、全角文字(幅2)を置く時に残り1マスしかなければ、その文字を
半分だけ描画したりはせず丸ごと次の行に送り、その行の最後の1マスは空白のまま残します。
これが起きるたびに、単純計算での位置と端末の実際のカーソル位置が1マスずつズレていき、
再描画はキー入力のたびに行われるので、そのズレがどんどん積み重なって上記の症状になって
いました。文字列を1文字ずつ実際に置いていく形でカーソル位置を計算するよう修正し、実際の
端末が全角文字の折り返しを判断するのと同じ考え方に揃えました。

**修正:** 実機のPowerMac G4(Mac OS X 10.4.0、ビルド8A428)で、矢印キーでカーソルを
左に動かしてからBackspaceを押すと、見た目のカーソル位置とは違う場所の文字が
消えてしまう不具合(意図した文字が消えず、数文字先が消えることも)。実機に
SSHで直接繋いで原因を特定しました: この環境では`stty size`が、ごく普通の
ターミナルウィンドウでも`0 0`を返すことがあり、行編集の`_term_width`が
この`0`を「異常値」ではなく正しい桁数として扱ってしまっていました。その結果、
カーソル位置の再計算が常に「0列目」に潰れてしまい、矢印キーで動かすたびに
再描画で見た目のカーソルが行の先頭に飛ばされていました(実際の編集位置自体は
別途正しく管理されていて、Backspace自体は正しい場所を消していたのですが、
目に見えているカーソルの方が嘘をついていた、という状態です)。`0`を無効な
値として弾き、80にフォールバックするよう修正。実機と同じ0x0のウィンドウ
サイズを疑似端末で強制的に再現し、修正前後で症状が再現・解消することを
確認済みです。

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
