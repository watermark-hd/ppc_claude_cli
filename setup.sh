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
#   1. Let you choose Anthropic (Claude) or Gemini (free tier, no credit card),
#      explain how to get that provider's API key, and read it safely (not echoed)
#      Anthropic (Claude) か Gemini (無料枠、カード不要) を選び、その案内と
#      安全な入力(画面に表示しない)
#   2. Detect common mistakes (pasted angle brackets, blank input, truncated key)
#      よくある入力ミスの検出 (山括弧の貼り付け、空白、桁数など)
#   3. Save it to ~/.claude-agent-env (chmod 600)
#      ~/.claude-agent-env への保存 (chmod 600)
#   4. Install the ~/bin/advisor wrapper command and set up PATH
#      ~/bin/advisor ラッパーコマンドの設置とPATH設定
#   5. Do a real API call to confirm everything works
#      実際にAPIを叩いて疎通確認

set -e

ENV_FILE="$HOME/.claude-agent-env"
BIN_DIR="$HOME/bin"
CURL_BIN="$HOME/claude-toolchain/bin/curl"
CACERT="$HOME/claude-build/src/cacert.pem"
AGENT_SCRIPT="$HOME/claude-build/claude-agent.pl"

echo "=== iBook G4 Advisor Setup ==="
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

if [ -f "$ENV_FILE" ]; then
  echo "Using existing API key from $ENV_FILE (this is normal when upgrading)."
  echo "既存のAPIキー($ENV_FILE)をそのまま使います(バージョンアップ時は毎回これでOK)。"
  echo "To set a different key, delete this file and run this again:"
  echo "別のキーに変えたい場合は、このファイルを削除してからもう一度実行してください:"
  echo "  rm $ENV_FILE"
  echo ""
else
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

      echo "APIキーを入力してください(画面には表示されません) / Please enter your API key (it will not be shown):"
      printf "> "
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

      {
        printf 'export CLAUDE_PROVIDER=anthropic\n'
        printf 'export ANTHROPIC_API_KEY=%s\n' "$API_KEY"
      } > "$ENV_FILE"
      ;;
    *)
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

      echo "APIキーを入力してください(画面には表示されません) / Please enter your API key (it will not be shown):"
      printf "> "
      stty -echo 2>/dev/null || true
      read -r API_KEY
      stty echo 2>/dev/null || true
      echo ""

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

      {
        printf 'export CLAUDE_PROVIDER=gemini\n'
        printf 'export GEMINI_API_KEY=%s\n' "$API_KEY"
      } > "$ENV_FILE"
      ;;
  esac

  # 会話中に /claude と /gemini で行き来したい場合のために、もう片方の
  # キーも今のうちに追加できるようにする(任意、スキップ可)。
  if [ "$PROVIDER_CHOICE" = "1" ]; then
    OTHER_NAME="Gemini"
  else
    OTHER_NAME="Anthropic (Claude)"
  fi
  echo ""
  printf "会話中に /claude と /gemini で切り替えたいなら、%s のキーも今のうちに追加できます。追加しますか?\n" "$OTHER_NAME"
  printf "Add a %s key too, so you can switch mid-conversation with /claude and /gemini? [y/N]: " "$OTHER_NAME"
  read -r ADD_OTHER
  echo ""

  case "$ADD_OTHER" in
    y|Y|yes|YES)
      if [ "$PROVIDER_CHOICE" = "1" ]; then
        echo "Gemini APIキーを入力してください(取得は https://aistudio.google.com/apikey )。"
        echo "Please enter your Gemini API key (get one at https://aistudio.google.com/apikey):"
      else
        echo "Anthropic APIキーを入力してください(取得は https://console.anthropic.com/ )。"
        echo "Please enter your Anthropic API key (get one at https://console.anthropic.com/):"
      fi
      printf "> "
      stty -echo 2>/dev/null || true
      read -r OTHER_KEY
      stty echo 2>/dev/null || true
      echo ""
      OTHER_KEY=$(echo "$OTHER_KEY" | sed 's/^[ \t]*//;s/[ \t]*$//')
      if [ -z "$OTHER_KEY" ]; then
        echo "何も入力されなかったので、この分はスキップします(後で $ENV_FILE を直接編集しても追加できます)。"
        echo "Nothing entered, skipping (you can add it later by editing $ENV_FILE directly)."
      else
        if [ "$PROVIDER_CHOICE" = "1" ]; then
          printf 'export GEMINI_API_KEY=%s\n' "$OTHER_KEY" >> "$ENV_FILE"
        else
          printf 'export ANTHROPIC_API_KEY=%s\n' "$OTHER_KEY" >> "$ENV_FILE"
        fi
        echo "$OTHER_NAME のキーも保存しました。"
      fi
      ;;
    *)
      : # スキップ
      ;;
  esac

  chmod 600 "$ENV_FILE"
  echo "Saved to $ENV_FILE (readable only by your account)"
  echo "$ENV_FILE に保存しました(あなたのアカウントだけが読めるファイルです)"
  echo ""
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
CLAUDE_PROVIDER="${CLAUDE_PROVIDER:-anthropic}"

# --- install the claude command / claude コマンドの設置 ---
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
  echo "Added $BIN_DIR to PATH (takes effect next login; to use it now, run"
  echo "'source ~/.bash_profile' or open a new terminal window)"
  echo "PATHに $BIN_DIR を追加しました(次回ログインから有効。今すぐ使うには"
  echo "'source ~/.bash_profile' を実行するか、新しいターミナルを開いてください)"
fi
echo ""

# --- connectivity check / 疎通確認 ---
echo "Checking API connectivity... / APIへの疎通を確認しています..."
RESPONSE_FILE="/tmp/claude-setup-check-$$.json"

if [ "$CLAUDE_PROVIDER" = "gemini" ]; then
  MODEL="${CLAUDE_MODEL:-gemini-3.6-flash}"
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
  echo "Connectivity OK. You're all set."
  echo "疎通確認OK。準備完了です。"
  echo ""
  echo "How to use: just type 'advisor' in the terminal."
  echo "使い方: ターミナルで 'advisor' と打つだけです。"
  echo "(If you added both keys, type /claude or /gemini inside a conversation to switch.)"
  echo "(両方のキーを追加した場合、会話中に /claude か /gemini と打てば切り替えられます)"
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
