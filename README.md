# Running Claude on a PowerPC iBook G4 (Mac OS X 10.4 Tiger)

**[English](#english) | [日本語](#japanese)**

<a id="english"></a>
## English

A project to keep an old PowerPC Mac useful as a real AI coding assistant, instead of
throwing it away. The official Claude Code CLI requires Node.js 18+, and V8 dropped
PowerPC support years ago, so it can't run there directly. Instead, this project is a
**self-contained, lightweight agent written in Perl that talks directly to an AI API over
curl** — either Anthropic (Claude) or, as of the latest version, Google's Gemini API,
which has a free tier that needs no credit card at all.

### Tested environment

- iBook G4 (PowerBook6,5), ~1.2GHz CPU, 1.25GB RAM
- Mac OS X 10.4.11 (Tiger), Darwin 8.11.0
- gcc 4.0.0 / make 3.80 / autoconf 2.59 / **Perl 5.8.6** (comes with the OS, no build needed)
- The stock curl 7.16.3 is linked against OpenSSL 0.9.7l and cannot connect over `https://`
  (`SSL23_GET_SERVER_HELLO:sslv3 alert handshake failure`)

### The real obstacle: TLS 1.2

Anthropic's API requires TLS 1.2 or newer, but Tiger's stock OpenSSL (0.9.7l) doesn't even
reach TLS 1.0. Upgrading Python alone doesn't fix this — **OpenSSL and curl themselves need
to be rebuilt from source**.

It gets trickier: trying to bootstrap via Tigerbrew or MacPorts hits a chicken-and-egg
problem, since fetching packages from GitHub etc. itself requires TLS 1.2 over HTTPS. This
project avoids that by downloading the source tarballs on a modern machine (which already
has TLS 1.2), transferring them to the iBook with `scp`, and then **building locally on the
iBook itself**. The actual (heavy) compilation work is genuinely done by the PowerPC/G4
hardware, so the goal of "running standalone on the G4" is preserved.

### Setup

#### 1. Fetch and transfer sources (run on a modern machine)

```bash
cd build/
./fetch-sources.sh          # fetches OpenSSL 1.0.2u, curl, and the latest cacert.pem
scp dist/*.tar.gz dist/cacert.pem ibook:~/claude-build/src/
```

#### 2. Build OpenSSL (on the iBook)

```bash
ssh ibook
~/claude-build/remote-build-openssl.sh
```

`make depend` may fail because `makedepend` is missing (it comes from X11 dev tools, not
included in Tiger's stock Developer Tools). Header dependency tracking isn't needed for a
one-off build, so it's fine to skip it and `make` directly (the script already does this).

It installs into `~/claude-toolchain/` (under your home directory), leaving the system's
curl/OpenSSL untouched. `/usr/local` is owned by root and typically not writable by a
regular Tiger user, so this avoids assuming sudo is available. Build time on a 1.2GHz G4:
roughly 30–40 minutes for OpenSSL.

#### 3. Build curl (on the iBook)

```bash
~/claude-build/remote-build-curl.sh
```

Produces a TLS 1.2/1.3-capable curl at `~/claude-toolchain/bin/curl`, linked against the
OpenSSL you just built. Takes around 40 minutes on the G4.

**Important gotcha**: Darwin's `ld` can prefer the system's `/usr/lib/libssl.dylib` (OpenSSL
0.9.7l on Tiger) over your custom-built `.a` files, even when `-L` points at your own
prefix. When this happens, fairly recent symbols like `EVP_sha256` or
`SSL_CTX_set_alpn_protos` all come up "undefined," and the binary crashes at runtime with
`dyld: Symbol not found` — a confusing failure mode that looks like a TLS problem but is
actually just the linker grabbing the wrong library. `remote-build-curl.sh` sets
`LDFLAGS="-L$PREFIX/lib -Wl,-search_paths_first"` to force the linker to search the given
`-L` path first (before falling back to system paths), which fixes this.

#### 4. Verify

```bash
~/claude-toolchain/bin/curl -v --cacert ~/claude-build/src/cacert.pem https://api.anthropic.com/
```

If you see `SSL connection using TLSv1.2 / ...`, the handshake succeeded — the core
obstacle is cleared.

#### 5. Set up your API key and the `advisor` command

Once `claude-agent.pl` is in `~/claude-build/`, run the included `setup.sh`. It first asks
which provider to use — **Anthropic (Claude)**, the more capable option that needs a
pay-as-you-go billing account, or **Gemini (Google)**, which has a free tier and no credit
card requirement (defaults to Gemini). Either way, it then walks you through getting that
provider's key, reads it without echoing it to the screen, detects common paste mistakes,
saves it, installs the `advisor` command, and does a real connectivity check.

```bash
scp agent/claude-agent.pl setup.sh ibook:~/claude-build/
ssh ibook
bash ~/claude-build/setup.sh
```

If you don't have a key yet, follow the script's instructions:
- Anthropic: create one at [console.anthropic.com](https://console.anthropic.com/)
  (**a different site from claude.ai**) under "API Keys", and add a small amount of credit
  under "Billing".
- Gemini: create one at [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
  with any Google account — no billing setup needed for the free tier.

Once setup finishes, open a new terminal (or run `source ~/.bash_profile`) and just type
`advisor` to start — the same command either way; which provider it talks to is whatever
`setup.sh` saved to `~/.claude-agent-env`. To switch later, delete that file and run
`setup.sh` again. (It's called `advisor` rather than something Claude- or Gemini-specific
on purpose — whoever's using it shouldn't have to know or care which AI is answering.)

### About the agent (`agent/claude-agent.pl`)

- **A single file, zero external CPAN dependencies** — runs on Tiger's stock Perl 5.8.6 alone
- JSON encode/decode is a small hand-written recursive-descent parser, just enough for the
  Claude/Gemini APIs' message structures
- Implements four tools: `read_file` / `write_file` / `list_dir` / `run_shell`
- File writes and shell commands prompt for confirmation before running, to avoid accidents
- HTTP is handled by shelling out to the curl binary you built (keeping TLS entirely out of
  Perl, so the only two things that need building are OpenSSL and curl)
- The system prompt tells the model to reply in whatever language the user writes in, so
  conversations switch between English/Japanese/etc. automatically — no client-side
  language detection needed
- Conversation history is always kept internally in Anthropic's Messages-API shape; when
  `CLAUDE_PROVIDER=gemini`, it's translated to and from Gemini's `contents`/`parts` shape
  only at the moment of the API call, so the terminal input handling and tool execution
  code don't need to know or care which provider is active
- Typing `/claude` or `/gemini` mid-conversation switches providers on the fly — handy if
  you want Claude's extra capability for real coding work but Gemini's free tier the rest
  of the time (e.g. handing the machine to a kid). If that provider's key isn't in the
  environment yet (`setup.sh` can save both up front, see below), it's prompted for right
  there, hidden like a password field — press Esc or Ctrl+C to back out instead, and
  nothing changes. Enter it once and it can optionally be saved to `~/.claude-agent-env`
  for next time. The existing conversation history carries over across the switch since
  it's provider-agnostic

### Notes on distributing this (about billing)

This repository (the build scripts and the agent itself) is free to share, but **actually
using the API requires each person to get their own API key.**

- No API key is embedded in the code anywhere (`claude-agent.pl` only reads it from an
  environment variable). Sharing this project never exposes your key or billing to anyone
  else
- With Gemini, the free tier (no credit card, generous daily quota on the Flash models) is
  enough for casual use — someone can start using this without spending anything
- With Anthropic, anyone who downloads it needs to create their own account at
  [console.anthropic.com](https://console.anthropic.com/) and add credit under Billing
  (this is separate, pay-as-you-go billing — not the same as a claude.ai Pro/Max
  subscription)
- `setup.sh` walks the user through all of this for whichever provider they pick, so people
  unfamiliar with API keys aren't left guessing

### Gotchas we hit

- **SSH key exchange gets rejected**: modern OpenSSH clients refuse Tiger's stock sshd
  (which only offers ssh-rsa/ssh-dss). Add this to `~/.ssh/config`:
  ```
  Host ibook
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedAlgorithms +ssh-rsa
  ```
- **`make depend` fails with `makedepend: command not found`**: skip it as described above
- **The iBook itself can't use HTTPS/git/wget**: fetch sources on a modern machine and
  `scp` them over
- **Can't write to `/usr/local`**: sudo needs an interactive password that isn't available
  over batch-mode SSH, so install into a user-owned directory like `~/claude-toolchain`
  instead
- **Linking curl leaves a pile of undefined symbols**: as above, use
  `-Wl,-search_paths_first` to prefer your own `.a` files over the system's old dylibs
- **Configuring OpenSSL with `shared` bites you later**: the dylib's `install_name` bakes in
  the prefix used at Configure time, so changing the install location afterward breaks it
  with `dyld: Library not loaded`. Building `no-shared` (static only) avoids this
- **If the iBook sleeps mid-build, the SSH session dies with it**: disable system sleep
  temporarily in Energy Saver during long builds
- **API keys get confused with the claude.ai password**: the API key is a separate thing,
  issued at console.anthropic.com
- **Pasting the placeholder `<...>` brackets from an example along with the key**: the
  shell interprets `<`/`>` as redirection, so `ANTHROPIC_API_KEY` silently ends up empty.
  `setup.sh` detects and warns about this
- **Gemini 3 requires echoing back a `thoughtSignature` on tool calls**: when the model
  returns a `functionCall` part, it comes with an opaque `thoughtSignature`. Send the next
  turn back without that exact signature attached to that same part, and the call fails
  with a 400 — this was optional on Gemini 2.5 but is enforced on Gemini 3. The agent
  carries it along on the internal `tool_use` block and re-attaches it when re-serializing
  to Gemini's `contents` format
- **Reading the API response with `:encoding(UTF-8)` can corrupt multibyte text**: same
  root cause as the STDIN issue above — Perl 5.8.6's PerlIO `:encoding(UTF-8)` layer can
  split a multibyte character across a buffer boundary and throw `utf8 "\xXX" does not map
  to Unicode`. This showed up when a `run_shell` result contained Japanese filenames (e.g. a
  `ダウンロード` folder). Fixed the same way: read the response as raw bytes, then decode
  the whole string at once with `Encode::decode`

### License / disclaimer

Each upstream source (OpenSSL, curl) follows its own project's license. The build scripts
and agent included here are free to modify and redistribute. Hopefully this helps the
community that keeps old machines alive and useful.

---

<a id="japanese"></a>
## 日本語

古いPowerPCマシンを捨てずに、実用的なAIコーディングアシスタントとして活かすためのプロジェクトです。
公式の Claude Code CLI は Node.js (18+) が前提で、V8 が PowerPC 対応を打ち切っているため直接は動きません。
そこで **curl 経由でAI APIを直接叩く自己完結型の軽量エージェント** を Perl で実装しています。使うAPIは
Anthropic (Claude) か、最新版で対応したGoogleのGemini API(クレジットカード不要の無料枠あり)から選べます。

### 動作確認環境

- iBook G4 (PowerBook6,5), CPU 約1.2GHz, RAM 1.25GB
- Mac OS X 10.4.11 (Tiger), Darwin 8.11.0
- gcc 4.0.0 / make 3.80 / autoconf 2.59 / **Perl 5.8.6** (標準搭載、追加ビルド不要)
- 標準の curl 7.16.3 は OpenSSL 0.9.7l にリンクされており `https://` に接続できない
  (`SSL23_GET_SERVER_HELLO:sslv3 alert handshake failure`)

### 本質的な壁: TLS 1.2

AnthropicのAPIサーバーはTLS 1.2以上を要求しますが、Tiger標準のOpenSSLは0.9.7l系でTLS 1.0にも
満たない世代です。「Pythonのバージョンを上げる」だけでは解決せず、**OpenSSLとcurlを新しくビルド
し直す**必要があります。

さらに厄介なのは、TigerbrewやMacPorts経由でパッケージを入れようとしても、その取得自体が
GitHub等のTLS 1.2必須なHTTPS接続を要求するため「新しいcurlを入れるために新しいcurlが要る」
という鶏卵問題にぶつかることです。本プロジェクトではこれを避けるため、ソースtarballは
別のモダンな端末(TLS1.2が使える環境)でダウンロードし、`scp`でiBookに転送してから
**iBook上でローカルビルド**する方式を取っています。ビルドという最も重い処理自体はきちんと
iBook本体(PowerPC/G4)が行うので、「G4単体で動かす」という目標は損なわれません。

### セットアップ手順

#### 1. ソースの取得と転送(モダン環境側で実行)

```bash
cd build/
./fetch-sources.sh          # OpenSSL 1.0.2u, curl, 最新cacert.pem を取得
scp dist/*.tar.gz dist/cacert.pem ibook:~/claude-build/src/
```

#### 2. OpenSSLをビルド(iBook上)

```bash
ssh ibook
~/claude-build/remote-build-openssl.sh
```

`make depend` は `makedepend` コマンド不在で失敗することがあります(X11開発ツール由来で
Tiger標準のDeveloper Toolsには含まれていません)。ヘッダの依存関係追跡は一度きりのビルドには
不要なため、スキップして直接 `make` すれば問題ありません(スクリプトは既にスキップする形に
なっています)。

`~/claude-toolchain/` (ユーザーのホーム配下)に隔離インストールされ、システム標準のcurl/opensslは
変更されません。`/usr/local` はroot所有でTiger標準ユーザーには書き込み権限が無いことが多いため、
sudoが使える前提を置かずホームディレクトリ配下にインストールする設計にしています。
G4 1.2GHzでのビルド時間の目安: OpenSSLで30〜40分程度。

#### 3. curlをビルド(iBook上)

```bash
~/claude-build/remote-build-curl.sh
```

新しいOpenSSLをリンクした、TLS 1.2/1.3対応のcurlが `~/claude-toolchain/bin/curl` にできます。
G4での所要時間は40分前後。

**重要な注意点**: Darwin(Mac OS X)の `ld` は、`-L` で独自prefixを指定していても
`-lssl -lcrypto` のようなライブラリ名指定に対して **システム標準の `/usr/lib/libssl.dylib`
(Tigerの場合OpenSSL 0.9.7l)を独自ビルドの `.a` より優先してリンクしてしまう**ことがあります。
これが起きると、TLS 1.2どころか `EVP_sha256` や `SSL_CTX_set_alpn_protos` のような比較的新しい
シンボルが軒並み「未定義」になり、実行時に `dyld: Symbol not found` で落ちます(一見TLSの問題に
見えますが、実際はリンカが古いシステムライブラリを掴んでいるだけ、という紛らわしい失敗モードです)。
`remote-build-curl.sh` では `LDFLAGS="-L$PREFIX/lib -Wl,-search_paths_first"` を明示することで、
指定した `-L` パスを素直に(システムパスより先に)探すよう強制し、この問題を回避しています。

#### 4. 動作確認

```bash
~/claude-toolchain/bin/curl -v --cacert ~/claude-build/src/cacert.pem https://api.anthropic.com/
```

`SSL connection using TLSv1.2 / ...` が出てハンドシェイクが成功すれば壁は突破です。

#### 5. APIキーの設定と `advisor` コマンドのセットアップ

`claude-agent.pl` を `~/claude-build/` に配置したら、付属の `setup.sh` を実行してください。
最初に「どちらのAIを使うか」を聞かれます — 一番賢いけど従量課金でクレジットカードが必要な
**Anthropic (Claude)**か、無料枠がありクレジットカード不要な**Gemini (Google)**か(デフォルトは
Gemini)。選んだ後は、そのプロバイダのキーの案内・入力(画面には表示されません)・よくある
入力ミスの検出・保存・`advisor` コマンドの設置・実際の疎通確認までを自動でやってくれます。

```bash
scp agent/claude-agent.pl setup.sh ibook:~/claude-build/
ssh ibook
bash ~/claude-build/setup.sh
```

キーをまだ持っていない場合は、スクリプトの案内に沿って発行してください。
- Anthropic: [console.anthropic.com](https://console.anthropic.com/)(**claude.aiとは別サイト**)
  の「API Keys」から発行し、「Billing」で少額のクレジットをチャージします。
- Gemini: [aistudio.google.com/apikey](https://aistudio.google.com/apikey)で、お持ちの
  Googleアカウントで発行できます。無料枠を使う分にはクレジットカードの登録は不要です。

セットアップが終わったら、新しいターミナル(または `source ~/.bash_profile`)で `advisor` と
打つだけで起動します。コマンド名はどちらのプロバイダでも同じ`advisor`で、実際にどちらと話すかは
`setup.sh`が`~/.claude-agent-env`に保存した内容次第です。後で切り替えたくなったら、
そのファイルを削除して`setup.sh`をもう一度実行してください。(コマンド名をあえてClaudeや
Gemini固有にしていないのは、使う人がどっちのAIが答えてるか意識しなくていいようにするためです)

### エージェントについて (`agent/claude-agent.pl`)

- **単一ファイル、外部CPANモジュール依存ゼロ** — Tiger標準のPerl 5.8.6だけで動きます
- JSON encode/decodeはClaude/Gemini両APIのメッセージ構造に必要な範囲を自前実装(再帰下降パーサー)
- 4つのツールを実装: `read_file` / `write_file` / `list_dir` / `run_shell`
- ファイル書き込みとシェル実行は誤操作防止のため実行前に確認プロンプトを出します
- HTTP通信は新しくビルドしたcurlをサブプロセスとして呼び出す方式(Perl側にTLS実装を持たせない
  ことで、ビルドの複雑さをOpenSSL/curlの2つだけに閉じ込めています)
- システムプロンプトで「ユーザーが書いた言語で返答する」よう指示しているため、
  ターミナル側で言語判定をしなくても日本語/英語などが自動で切り替わります
- 会話履歴は常にAnthropicのMessages API形式で内部保持していて、`CLAUDE_PROVIDER=gemini`の
  時だけAPI呼び出しの直前・直後にGeminiの`contents`/`parts`形式との変換をかけています。
  なので、ターミナル入力周りやツール実行のコードはどちらのプロバイダかを一切気にしなくて
  済む設計です
- 会話中に `/claude` または `/gemini` と打つと、その場でプロバイダを切り替えられます。
  普段の込み入ったコーディングにはClaude、それ以外(子供に触らせる時など)は無料のGemini、
  といった使い分けができます。切り替え先のキーが環境に無い場合は、その場でパスワード欄の
  ように画面に表示せず入力するよう促されます(`setup.sh`で最初から両方保存しておくことも
  できます、下記参照)。Escか Ctrl+Cで入力をキャンセルすれば何も変わらず元のプロバイダの
  ままです。1回入力すれば、次回のために `~/.claude-agent-env` へ保存するか選べます。
  会話履歴はプロバイダに依存しない形式なので、
  切り替えてもそれまでの会話はそのまま引き継がれます

### 配布して使う場合の注意(課金について)

このリポジトリ(ビルドスクリプトとエージェント本体)自体は自由に配布できますが、
**実際にAPIを使うには、使う人ひとりひとりが自分でAPIキーを発行する**必要があります。

- コードにAPIキーは一切含まれていません(`claude-agent.pl` は環境変数からキーを
  読むだけ)。配布者のキーや請求先が他人に渡ることはありません
- Geminiなら、無料枠(クレジットカード不要、Flash系モデルなら1日あたりかなりの回数まで無料)
  だけで気軽に使い始められます。お金を一切かけずに試せます
- Anthropicの場合、ダウンロードした人はそれぞれ [console.anthropic.com](https://console.anthropic.com/)
  でアカウントを作り、Billingでクレジットをチャージする必要があります
  (claude.aiのPro/Max等のサブスクリプションとは別の、従量課金の仕組みです)
- `setup.sh` がどちらを選んでも上記の案内・キー入力・保存・動作確認までをガイドしてくれるので、
  配布先の人がAPIキーの扱いに詳しくなくても迷いにくい設計にしています

### ハマりどころ集

- **SSHの鍵交換方式が拒否される**: 最近のOpenSSHクライアントはTiger標準のsshd(ssh-rsa/ssh-dssのみ
  offer)を拒否します。`~/.ssh/config` に以下を追加してください。
  ```
  Host ibook
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedAlgorithms +ssh-rsa
  ```
- **`make depend` が `makedepend: command not found` で失敗する**: 上記の通りスキップして問題なし
- **iBook自身はHTTPS/git/wgetが使えない**: ソース取得は別のモダン環境で行い `scp` で転送する
- **`/usr/local` に書き込めない**: sudoの対話パスワードがBatchModeのSSH経由では使えないため、
  `~/claude-toolchain` のようなユーザー所有ディレクトリにインストールする
- **curlのリンク時に大量のシンボルが未定義になる**: 上記の通り `-Wl,-search_paths_first` で
  システムの古いdylibより自前ビルドの `.a` を優先させる
- **OpenSSLを `shared` でConfigureすると後で詰む**: dylibの `install_name` にConfigure時点の
  prefixが焼き込まれるため、後でインストール先を変えると `dyld: Library not loaded` になる。
  `no-shared` で静的ライブラリのみ作るのが無難
- **ビルド中にiBookがスリープすると SSH セッションごと切れる**: 長時間ビルドの間は
  省エネルギー設定でシステムスリープを一時的に無効にしておく
- **APIキーとclaude.aiのパスワードを混同しやすい**: APIキーは console.anthropic.com で別途発行する
- **説明文の `<...>` (プレースホルダー記号)を含めたままキーを貼り付けてしまう**: シェルでは
  `<` `>` はリダイレクト記号として解釈され、`ANTHROPIC_API_KEY` が空のまま静かに失敗する。
  `setup.sh` はこのミスを検出して警告するようにしてある
- **Gemini 3はツール呼び出しの`thoughtSignature`を送り返さないと400エラーになる**: モデルが
  `functionCall`を返す時、そこには不透明な`thoughtSignature`という署名が付いてくる。次のターンで
  同じパーツに同じ署名を付け直さずに送り返すと400エラーになる — Gemini 2.5までは任意だったが、
  3系では必須の検証に変わっている。エージェントは内部の`tool_use`ブロックにこれを乗せておいて、
  Geminiの`contents`形式に再変換する時に付け直すようにしている
- **APIレスポンスを`:encoding(UTF-8)`で読むとマルチバイト文字が化けることがある**: 上のSTDINの
  問題と同じ原因で、Perl 5.8.6のPerlIO `:encoding(UTF-8)`層は、バッファの境目でマルチバイト文字が
  分割されると`utf8 "\xXX" does not map to Unicode`という警告と文字化けを起こす。`run_shell`の
  結果に日本語ファイル名(`ダウンロード`フォルダなど)が含まれていた時に発覚した。直し方も同じで、
  生バイトのまま読んでから、まとめて`Encode::decode`で一度にデコードするようにしている

### ライセンス / 免責

各ソース(OpenSSL, curl)は各プロジェクトのライセンスに従います。ここに含まれるビルドスクリプト
とエージェント本体は自由に改変・再配布して構いません。古いマシンを大切にするコミュニティの
一助になれば幸いです。
