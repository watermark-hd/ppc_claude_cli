#!/bin/bash
# Double-click this file in the Finder to install.
# Finderでこのファイルをダブルクリックするとインストールが始まります。
#
# This uses a prebuilt curl (TLS 1.2/1.3 capable, statically linked against
# OpenSSL 1.0.2u) so no compiling is needed on your Mac.
# TLS 1.2/1.3対応の curl をビルド済みで同梱しているので、あなたのMac上での
# コンパイル作業は不要です。

cd "$(dirname "$0")"
set -e

echo "=================================================="
echo " Claude Agent for PowerPC Mac - Installer"
echo " PowerPC Mac用 Claude Agent インストーラー"
echo "=================================================="
echo ""

TOOLCHAIN_DIR="$HOME/claude-toolchain"
BUILD_DIR="$HOME/claude-build"
BIN_DIR="$HOME/bin"

mkdir -p "$TOOLCHAIN_DIR/bin"
mkdir -p "$BUILD_DIR/src"

echo "Installing curl (TLS 1.2/1.3 capable, prebuilt for PowerPC Tiger)..."
echo "curl をインストールしています(PowerPC Tiger向けビルド済み)..."
cp -f curl "$TOOLCHAIN_DIR/bin/curl"
chmod +x "$TOOLCHAIN_DIR/bin/curl"

echo "Installing the agent and CA certificate bundle..."
echo "エージェント本体とCA証明書を配置しています..."
cp -f claude-agent.pl "$BUILD_DIR/claude-agent.pl"
cp -f cacert.pem "$BUILD_DIR/src/cacert.pem"

echo ""
echo "Checking that curl actually works on this Mac..."
echo "このMacで curl が実際に動くか確認しています..."
if ! "$TOOLCHAIN_DIR/bin/curl" --version > /dev/null 2>&1; then
  echo ""
  echo "Error: the prebuilt curl did not run on this machine."
  echo "エラー: 同梱のcurlがこのMacでは動作しませんでした。"
  echo "This binary was built and tested on an iBook G4 (Mac OS X 10.4.11 Tiger)."
  echo "このバイナリは iBook G4 (Mac OS X 10.4.11 Tiger) でビルド・動作確認したものです。"
  echo "It may not be compatible with your Mac's OS version or processor."
  echo "お使いのMacのOSバージョンやプロセッサでは互換性が無い可能性があります。"
  echo "In that case, please build curl from source yourself -- see README.md"
  echo "(build/ directory) in the full project."
  echo "その場合は README.md の build/ 以下の手順でソースからビルドしてください。"
  echo ""
  printf "Press Enter to finish (this window may stay open; you can close it yourself) / Enterキーで完了します(ウィンドウは自動では閉じないことがあります。閉じて構いません): "
  read -r _
  exit 1
fi
echo "OK"
echo ""

# ------------------------------------------------------------------
# API key setup / APIキーのセットアップ
# ------------------------------------------------------------------
ENV_FILE="$HOME/.claude-agent-env"
CURL_BIN="$TOOLCHAIN_DIR/bin/curl"
CACERT="$BUILD_DIR/src/cacert.pem"
AGENT_SCRIPT="$BUILD_DIR/claude-agent.pl"

if [ -f "$ENV_FILE" ]; then
  overwrite="n"
  echo "Using existing API key from $ENV_FILE (this is normal when upgrading)."
  echo "既存のAPIキー($ENV_FILE)をそのまま使います(バージョンアップ時は毎回これでOK)。"
  echo "To set a different key, delete this file and run the installer again:"
  echo "別のキーに変えたい場合は、このファイルを削除してからもう一度実行してください:"
  echo "  rm $ENV_FILE"
else
  overwrite="y"
fi

case "$overwrite" in
  y|Y)
    echo ""
    echo "Which AI should this agent talk to?"
    echo "どちらのAIを使いますか?"
    echo "  1) Anthropic (Claude) - most capable, pay-as-you-go billing, needs a credit card"
    echo "     Anthropic (Claude) - 一番賢い。従量課金制で、クレジットカードが必要です"
    echo "  2) Gemini (Google) - free tier, no credit card needed, plenty for casual chatting"
    echo "     Gemini (Google) - 無料枠あり。クレジットカード不要。気軽に使う分には十分です"
    echo ""
    printf "Enter 1 or 2 (default: 2) / 1か2を入力 (デフォルト: 2): "
    read -r PROVIDER_CHOICE
    echo ""

    case "$PROVIDER_CHOICE" in
      1)
        PROVIDER="anthropic"
        echo "You need an Anthropic API key. If you don't have one yet:"
        echo "Anthropic APIキーが必要です。まだお持ちでない場合:"
        echo "  1. Open https://console.anthropic.com/ (NOT the same site as claude.ai)"
        echo "     https://console.anthropic.com/ を開く (claude.aiとは別サイトです)"
        echo "  2. Create an account / sign in"
        echo "     アカウントを作成 / ログイン"
        echo "  3. Go to 'API Keys' in the left menu and create a new key"
        echo "     左メニューの 'API Keys' から新しいキーを発行"
        echo "  4. Add a small amount of credit under 'Billing' (pay-as-you-go)"
        echo "     'Billing' で少額のクレジットをチャージ(従量課金)"
        echo ""
        echo "Note: this is NOT the password you use to log in to claude.ai."
        echo "注意: claude.aiにログインする時のパスワードとは別物です。"
        echo "The API key is a long string starting with 'sk-ant-api03-'."
        echo "'sk-ant-api03-' で始まる長い文字列がAPIキーです。"
        echo ""
        ;;
      *)
        PROVIDER="gemini"
        echo "You need a Gemini API key (free, no credit card required). If you don't have one yet:"
        echo "Gemini APIキーが必要です(無料、クレジットカード不要)。まだお持ちでない場合:"
        echo "  1. Open https://aistudio.google.com/apikey"
        echo "     https://aistudio.google.com/apikey を開く"
        echo "  2. Sign in with any Google account"
        echo "     お持ちのGoogleアカウントでログイン"
        echo "  3. Click 'Create API key' and choose (or create) a Google Cloud project"
        echo "     'Create API key' をクリックし、Google Cloudプロジェクトを選択(または新規作成)"
        echo "  4. No billing/credit card setup is needed for the free tier"
        echo "     無料枠を使う分にはクレジットカードの登録は不要です"
        echo ""
        echo "The API key usually starts with 'AIzaSy', though Google sometimes issues other formats too."
        echo "APIキーは多くの場合 'AIzaSy' から始まりますが、それ以外の形式のこともあります。"
        echo ""
        ;;
    esac

    printf "Paste your API key and press Enter (it will not be shown) / APIキーを貼り付けてEnter(画面には表示されません): "
    stty -echo 2>/dev/null || true
    read -r API_KEY
    stty echo 2>/dev/null || true
    echo ""

    API_KEY=$(echo "$API_KEY" | sed 's/^[ \t]*//;s/[ \t]*$//')

    if [ -z "$API_KEY" ]; then
      echo "Error: nothing was entered. Please run this installer again."
      echo "エラー: 何も入力されませんでした。もう一度インストーラーを実行してください。"
      printf "Press Enter to finish (this window may stay open; you can close it yourself) / Enterキーで完了します(ウィンドウは自動では閉じないことがあります。閉じて構いません): "
      read -r _
      exit 1
    fi

    case "$API_KEY" in
      \<*|*\>)
        echo "Error: found '<' or '>' in the input."
        echo "エラー: '<' か '>' が含まれています。"
        echo "Did you accidentally paste the placeholder brackets from an example?"
        echo "説明文のプレースホルダー記号を誤って一緒に貼り付けていませんか?"
        echo "Paste just the key value, without the angle brackets, and run this again."
        echo "記号を含めず、キーの値だけを貼り付けて、もう一度実行してください。"
        printf "Press Enter to finish (this window may stay open; you can close it yourself) / Enterキーで完了します(ウィンドウは自動では閉じないことがあります。閉じて構いません): "
        read -r _
        exit 1
        ;;
    esac

    if [ "$PROVIDER" = "anthropic" ]; then
      case "$API_KEY" in
        sk-ant-api*) ;;
        *)
          echo "Warning: this doesn't start with 'sk-ant-api'."
          echo "警告: 'sk-ant-api' で始まっていません。"
          echo "Did you paste your claude.ai password or something else by mistake?"
          echo "claude.aiのパスワードなど別のものを貼り付けていませんか?"
          echo "Continuing anyway, but the connectivity check below may fail."
          echo "このまま処理を続けますが、動作確認で失敗する可能性があります。"
          ;;
      esac

      key_len=$(echo -n "$API_KEY" | wc -c | tr -d ' ')
      if [ "$key_len" -lt 50 ]; then
        echo "Warning: the key is only ${key_len} characters. Was it cut off during copy?"
        echo "警告: キーが ${key_len} 文字しかありません。コピーが途中で切れていませんか?"
      fi

      {
        printf 'export CLAUDE_PROVIDER=anthropic\n'
        printf 'export ANTHROPIC_API_KEY=%s\n' "$API_KEY"
      } > "$ENV_FILE"
    else
      {
        printf 'export CLAUDE_PROVIDER=gemini\n'
        printf 'export GEMINI_API_KEY=%s\n' "$API_KEY"
      } > "$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE"
    echo "Saved to $ENV_FILE (readable only by your account)"
    echo "$ENV_FILE に保存しました(あなたのアカウントだけが読めるファイルです)"
    ;;
  *)
    echo "Keeping the existing key. / 既存のキーをそのまま使います。"
    ;;
esac
echo ""

# ------------------------------------------------------------------
# advisor command / advisor コマンド
# ------------------------------------------------------------------
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/advisor" << WRAPEOF
#!/bin/bash
source $ENV_FILE
export CLAUDE_CURL=$CURL_BIN
export CLAUDE_CACERT=$CACERT
exec perl $AGENT_SCRIPT
WRAPEOF
chmod +x "$BIN_DIR/advisor"
echo "Created $BIN_DIR/advisor"
echo "$BIN_DIR/advisor を作成しました。"

if ! grep -qF 'export PATH=$HOME/bin:$PATH' "$HOME/.bash_profile" 2>/dev/null; then
  echo "export PATH=\$HOME/bin:\$PATH" >> "$HOME/.bash_profile"
fi
echo ""

# ------------------------------------------------------------------
# connectivity check / 疎通確認
# ------------------------------------------------------------------
echo "Checking API connectivity... / APIへの疎通を確認しています..."
source "$ENV_FILE"
CLAUDE_PROVIDER="${CLAUDE_PROVIDER:-anthropic}"
RESPONSE_FILE="/tmp/claude-install-check-$$.json"

if [ "$CLAUDE_PROVIDER" = "gemini" ]; then
  MODEL="${CLAUDE_MODEL:-gemini-3.5-flash-lite}"
  # thinkingConfigを省略するとGemini 3系は既定で"HIGH"(深く考える)になり、
  # ただの疎通確認でも数十秒待たされることがあるため、LOWを明示する。
  HTTP_CODE=$("$CURL_BIN" -s --cacert "$CACERT" \
    "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -H "content-type: application/json" \
    -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":10,"thinkingConfig":{"thinkingLevel":"LOW"}}}' \
    -o "$RESPONSE_FILE" \
    -w "%{http_code}")
else
  HTTP_CODE=$("$CURL_BIN" -s --cacert "$CACERT" \
    https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-sonnet-4-5-20250929","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' \
    -o "$RESPONSE_FILE" \
    -w "%{http_code}")
fi

echo ""
if [ "$HTTP_CODE" = "200" ]; then
  echo "=================================================="
  echo " Setup complete! / セットアップ完了！"
  echo "=================================================="
  echo ""
  echo "Open a NEW Terminal window and just type: advisor"
  echo "新しいターミナルウィンドウを開いて 'advisor' と入力するだけです。"
else
  echo "API error (HTTP $HTTP_CODE)."
  echo "APIエラー(HTTP $HTTP_CODE)。"
  if [ "$CLAUDE_PROVIDER" = "gemini" ]; then
    echo "Check that your Gemini API key is correct."
    echo "Geminiのキーが正しいか確認してください。"
  else
    echo "Check that your key is correct and that you have credit charged in the Console."
    echo "キーが正しいか、Consoleでクレジットがチャージされているか確認してください。"
  fi
  echo "--- Server response / サーバーからの応答 ---"
  cat "$RESPONSE_FILE"
  echo ""
fi
rm -f "$RESPONSE_FILE"

echo ""
printf "Press Enter to finish (this window may stay open; you can close it yourself) / Enterキーで完了します(ウィンドウは自動では閉じないことがあります。閉じて構いません): "
read -r _
