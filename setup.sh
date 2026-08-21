#!/bin/bash
# Setup script for iBook/PowerMac (PPC Mac running Tiger or later).
# Run this after building ~/claude-toolchain (curl/OpenSSL) and placing
# ~/claude-build/claude-agent.pl (see README.md / build/).
#
# iBook/PowerMac (Tiger以降のPPC Mac) 上で実行するセットアップスクリプト。
# ビルド済みの ~/claude-toolchain (curl/OpenSSL) と ~/claude-build/claude-agent.pl
# がある状態で実行してください(ビルド手順は README.md / build/ を参照)。
#
# What this does / やること:
#   1. Explain how to get an Anthropic API key, and read it safely (not echoed)
#      Anthropic APIキーの案内 と 安全な入力(画面に表示しない)
#   2. Detect common mistakes (pasted angle brackets, blank input, truncated key)
#      よくある入力ミスの検出 (山括弧の貼り付け、空白、桁数など)
#   3. Save it to ~/.claude-agent-env (chmod 600)
#      ~/.claude-agent-env への保存 (chmod 600)
#   4. Install the ~/bin/claude wrapper command and set up PATH
#      ~/bin/claude ラッパーコマンドの設置とPATH設定
#   5. Do a real API call to confirm everything works
#      実際にAPIを叩いて疎通確認

set -e

ENV_FILE="$HOME/.claude-agent-env"
BIN_DIR="$HOME/bin"
CURL_BIN="$HOME/claude-toolchain/bin/curl"
CACERT="$HOME/claude-build/src/cacert.pem"
AGENT_SCRIPT="$HOME/claude-build/claude-agent.pl"

echo "=== iBook G4 Claude Agent Setup ==="
echo ""

if [ ! -x "$CURL_BIN" ]; then
  echo "Error: $CURL_BIN not found."
  echo "エラー: $CURL_BIN が見つかりません。"
  echo "Please build TLS-capable curl first with build/remote-build-openssl.sh"
  echo "and build/remote-build-curl.sh (see README.md)."
  echo "先に build/remote-build-openssl.sh と build/remote-build-curl.sh を"
  echo "実行してTLS対応curlをビルドしてください(README.md参照)。"
  exit 1
fi

if [ ! -f "$AGENT_SCRIPT" ]; then
  echo "Error: $AGENT_SCRIPT not found."
  echo "エラー: $AGENT_SCRIPT が見つかりません。"
  echo "Please place claude-agent.pl in ~/claude-build/."
  echo "claude-agent.pl を ~/claude-build/ に配置してください。"
  exit 1
fi

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

if [ -f "$ENV_FILE" ]; then
  printf "%s already exists. Overwrite? / 既に存在します。上書きしますか? [y/N] " "$ENV_FILE"
  read -r overwrite
  case "$overwrite" in
    y|Y) ;;
    *) echo "Cancelled. / 中止しました。"; exit 0 ;;
  esac
fi

printf "Paste your API key and press Enter (it will not be shown) / APIキーを貼り付けてEnter(画面には表示されません): "
stty -echo 2>/dev/null || true
read -r API_KEY
stty echo 2>/dev/null || true
echo ""

# trim leading/trailing whitespace / 前後の空白を除去
API_KEY=$(echo "$API_KEY" | sed 's/^[ \t]*//;s/[ \t]*$//')

if [ -z "$API_KEY" ]; then
  echo "Error: nothing was entered. Please run this again."
  echo "エラー: 何も入力されませんでした。もう一度実行してください。"
  exit 1
fi

case "$API_KEY" in
  \<*|*\>)
    echo "Error: found '<' or '>' in the input."
    echo "エラー: '<' か '>' が含まれています。"
    echo "Did you accidentally paste the placeholder brackets from an example?"
    echo "説明文のプレースホルダー記号を誤って一緒に貼り付けていませんか?"
    echo "Paste just the key value, without the angle brackets."
    echo "記号を含めず、キーの値だけを貼り付けてください。"
    exit 1
    ;;
esac

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

printf 'export ANTHROPIC_API_KEY=%s\n' "$API_KEY" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "Saved to $ENV_FILE (readable only by your account)"
echo "$ENV_FILE に保存しました(あなたのアカウントだけが読めるファイルです)"
echo ""

# --- install the claude command / claude コマンドの設置 ---
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/claude" << WRAPEOF
#!/bin/bash
source $ENV_FILE
export CLAUDE_CURL=$CURL_BIN
export CLAUDE_CACERT=$CACERT
exec perl $AGENT_SCRIPT
WRAPEOF
chmod +x "$BIN_DIR/claude"
echo "Created $BIN_DIR/claude"
echo "$BIN_DIR/claude を作成しました。"

if ! grep -qF 'export PATH=$HOME/bin:$PATH' "$HOME/.bash_profile" 2>/dev/null; then
  echo "export PATH=\$HOME/bin:\$PATH" >> "$HOME/.bash_profile"
  echo "Added $BIN_DIR to PATH (takes effect next login; to use it now, run"
  echo "'source ~/.bash_profile' or open a new terminal window)"
  echo "PATHに $BIN_DIR を追加しました(次回ログインから有効。今すぐ使うには"
  echo "'source ~/.bash_profile' を実行するか、新しいターミナルを開いてください)"
fi
echo ""

# --- connectivity check / 疎通確認 ---
echo "Checking API connectivity... / APIへの疎通を確認しています..."
RESPONSE_FILE="/tmp/claude-setup-check-$$.json"
HTTP_CODE=$("$CURL_BIN" -s --cacert "$CACERT" \
  https://api.anthropic.com/v1/messages \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-5-20250929","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' \
  -o "$RESPONSE_FILE" \
  -w "%{http_code}")

echo ""
if [ "$HTTP_CODE" = "200" ]; then
  echo "Connectivity OK. You're all set."
  echo "疎通確認OK。準備完了です。"
  echo ""
  echo "How to use: just type 'claude' in the terminal."
  echo "使い方: ターミナルで 'claude' と打つだけです。"
else
  echo "API error (HTTP $HTTP_CODE). Check that your key is correct and that"
  echo "you have credit charged in the Console."
  echo "APIエラー(HTTP $HTTP_CODE)。キーが正しいか、Consoleでクレジットが"
  echo "チャージされているか確認してください。"
  echo "--- Server response / サーバーからの応答 ---"
  cat "$RESPONSE_FILE"
  echo ""
fi
rm -f "$RESPONSE_FILE"
