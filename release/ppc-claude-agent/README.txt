AI Agent for PowerPC Mac (Tiger / 10.4)
============================================

HOW TO INSTALL / インストール方法
---------------------------------
1. Copy this whole folder onto your PowerPC Mac (USB stick, file sharing, etc.)
   このフォルダごとPowerPC Macにコピーしてください(USBメモリやファイル共有などで)。

2. Double-click "Install.command".
   「Install.command」をダブルクリックしてください。

3. A Terminal window opens. Choose Anthropic (Claude) or Gemini (Google) --
   Gemini has a free tier that needs no credit card at all. Then follow the
   prompts for that provider's API key (the installer explains how to get one).
   ターミナルが開きます。Anthropic (Claude) か Gemini (Google) かを選んで
   ください -- Geminiは無料枠があり、クレジットカードは不要です。あとは
   案内に沿って、選んだ方のAPIキーを入力してください(取得方法もインストー
   ラーが説明します)。

4. When it says "Setup complete!", open a NEW Terminal window and type:
   「セットアップ完了！」と出たら、新しいターミナルウィンドウを開いて
   次のように入力してください:

       advisor

That's it. No compiling, no MacPorts, no Xcode required.
コンパイルもMacPortsもXcodeも不要です。

REQUIREMENTS / 動作要件
------------------------
- A PowerPC Mac running Mac OS X 10.4 (Tiger) -- tested on an iBook G4
  (PowerBook6,5). Other PowerPC Macs on Tiger should work too, since the
  bundled curl was built without CPU-specific optimizations, but this
  hasn't been tested on every model. If "Install.command" reports that
  curl doesn't run on your machine, see the full project (README.md,
  build/ folder) to build it from source instead.
  PowerPC Mac + Mac OS X 10.4 (Tiger)。iBook G4 (PowerBook6,5) で動作確認
  済みです。他のPPC Tiger機でも動く可能性は高いですが、全機種での検証は
  していません。もし curl が動かないと出た場合は、README.md の build/
  以下の手順でソースからビルドしてください。

- Either an Anthropic API key (usage is billed separately, pay-as-you-go, at
  console.anthropic.com -- this is NOT the same as a claude.ai subscription)
  or a Gemini API key (free tier, no credit card needed, at
  aistudio.google.com/apikey). The installer asks which one you want.
  Anthropic APIキー(console.anthropic.comでの従量課金。claude.aiの
  サブスクリプションとは別物です)か、Gemini APIキー(aistudio.google.com/apikey
  で取得できる無料枠、クレジットカード不要)のどちらか。どちらを使うかは
  インストーラーが聞いてきます。

WHAT'S INSIDE / 同梱内容
-------------------------
- curl            : prebuilt, TLS 1.2/1.3-capable curl for PowerPC/Tiger
- cacert.pem       : current CA certificate bundle
- claude-agent.pl  : the agent itself (single Perl file, no dependencies)
- Install.command  : the installer you double-click

More detail, and how to build everything from source, is in the full
project's README.md.
より詳しい情報や、ソースから全てビルドする方法は、プロジェクト本体の
README.md にあります。
