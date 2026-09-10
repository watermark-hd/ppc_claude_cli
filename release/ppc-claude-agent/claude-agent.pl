#!/usr/bin/perl
# claude-agent.pl — iBook G4 (Mac OS X 10.4 Tiger, Perl 5.8.6) 向けの
# 自己完結型 Claude APIエージェント。外部CPANモジュールに依存しない。
#
# 前提: ~/claude-build/build/remote-build-*.sh でビルドした
#       /usr/local/claude-toolchain/bin/curl (TLS1.2/1.3対応) が使えること。
#
# 使い方:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   perl claude-agent.pl

use strict;
use warnings;
use utf8;  # このファイル自身に書かれた日本語リテラルをUTF-8として解釈する
use Encode qw(decode encode FB_DEFAULT);

# 画面出力は明示的にUTF-8として扱う。
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# STDINはあえて生バイトのまま(:encoding層を付けない)にしておく。
# Perl 5.8.6のPerlIO :encoding(UTF-8) は、実際のキーボード入力のように
# バイトが少しずつ届く対話的な読み込みだと、マルチバイト文字の途中で
# 読み込みバッファが分割されてしまい "utf8 does not map to Unicode" と
# いう文字化けエラーを起こすことがある(パイプ経由の一括入力では再現
# しない)。そのため、行を読み終えてバイト列が全部揃った後にまとめて
# デコードする(下のwhileループ内)方式にしている。

# :encoding層を付けるとSTDOUTの自動フラッシュが効かなくなり、プロンプトの
# 表示がAPI応答まで遅延して見えることがあるため、明示的に毎回flushする。
$| = 1;

# ------------------------------------------------------------------
# 設定
# ------------------------------------------------------------------
my $CURL      = $ENV{CLAUDE_CURL} || '/usr/local/claude-toolchain/bin/curl';
my $CACERT    = $ENV{CLAUDE_CACERT} || '/usr/local/claude-toolchain/cacert.pem';
my $MAX_TOKENS = 4096;
# setup.shが使うのと同じパス。/claude, /gemini で新しく入力したキーを
# 保存する時に使う(setup.shを介さない場合の書き込み先)。
my $ENV_FILE_PATH = ($ENV{HOME} || '.') . '/.claude-agent-env';

# プロバイダ切り替え。CLAUDE_PROVIDER=gemini でクレジットカード登録不要の
# Gemini API無料枠を使う(デフォルトはこれまで通りAnthropic)。会話中に
# /claude, /gemini でも切り替えられる(下の configure_provider 参照)。
my ($PROVIDER, $API_KEY, $MODEL, $API_URL, $ANTHROPIC_VERSION);

# $providerに応じて$API_KEY/$MODEL/$API_URL等を(再)設定する。起動時と、
# 会話中の /claude, /gemini コマンドの両方から呼ばれる。対応する環境変数
# (ANTHROPIC_API_KEY / GEMINI_API_KEY) が無い場合はdieする — 起動時は
# それでプログラムごと終了、実行中の切り替え時は呼び出し側でevalして
# catchし、今のプロバイダのまま継続する。
sub configure_provider {
    my ($provider) = @_;
    if ($provider eq 'gemini') {
        $ENV{GEMINI_API_KEY} or die "GEMINI_API_KEY を設定してください\n";
        $API_KEY = $ENV{GEMINI_API_KEY};
        $MODEL   = $ENV{CLAUDE_MODEL} || 'gemini-3.5-flash-lite';
        $API_URL = "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent";
    }
    elsif ($provider eq 'anthropic') {
        $ENV{ANTHROPIC_API_KEY} or die "ANTHROPIC_API_KEY を設定してください\n";
        $API_KEY = $ENV{ANTHROPIC_API_KEY};
        $MODEL   = $ENV{CLAUDE_MODEL} || 'claude-sonnet-4-5-20250929';
        $API_URL = 'https://api.anthropic.com/v1/messages';
        $ANTHROPIC_VERSION = '2023-06-01';
    }
    else {
        die "不明なプロバイダ: '$provider' (anthropic か gemini を指定してください)\n";
    }
    $PROVIDER = $provider;
}

configure_provider($ENV{CLAUDE_PROVIDER} || 'anthropic');

my $SYSTEM_PROMPT = <<'EOS';
You are a lightweight coding assistant running in the terminal of a
PowerPC iBook G4 (Mac OS X 10.4 Tiger). You have four tools available:
read_file, write_file, list_dir, and run_shell. Use them to read/write
files and run commands in the user's working directory. Keep replies
concise, and always reply in the same language the user wrote in
(if they write in Japanese, reply in Japanese; if English, reply in
English; and so on for other languages).

Environment quirks to keep in mind for run_shell, so you get it right on
the first try instead of trial-and-error (each attempt needs the user's
explicit y/N confirmation, so retries are especially disruptive here):
- The system's stock `curl` is linked against an old OpenSSL and cannot
  make HTTPS requests (TLS handshake failure). A modern, TLS-capable curl
  is available via the `$CLAUDE_CURL` environment variable instead - for
  any HTTPS fetch, use `"$CLAUDE_CURL" --cacert "$CLAUDE_CACERT" ...`
  rather than plain `curl`.
- If Python is needed, assume it's an old Python 2.x (no `urllib.request`,
  no f-strings, no `except X as e:` - use `except Exception, e:` and the
  legacy `urllib`/`urllib2` modules instead).
EOS

# ------------------------------------------------------------------
# 最小限のJSONエンコーダ/デコーダ (依存ゼロ、Claude APIのメッセージ
# 構造に必要な範囲をカバーする再帰下降パーサー)
# ------------------------------------------------------------------
package MiniJSON;

sub encode {
    my ($v) = @_;
    my $r = ref $v;
    if ($r eq 'HASH') {
        return '{' . join(',', map {
            encode_string($_) . ':' . encode($v->{$_})
        } sort keys %$v) . '}';
    } elsif ($r eq 'ARRAY') {
        return '[' . join(',', map { encode($_) } @$v) . ']';
    } elsif (!defined $v) {
        return 'null';
    } elsif ($r eq 'SCALAR') {
        return $$v ? 'true' : 'false';
    } elsif ($v =~ /^-?\d+(\.\d+)?([eE][+-]?\d+)?$/) {
        return $v;
    } else {
        return encode_string($v);
    }
}

sub encode_string {
    my ($s) = @_;
    $s =~ s/([\\"])/\\$1/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}

# decode: 文字列 -> Perlデータ構造。posを進めながら解析する。
sub decode {
    my ($text) = @_;
    my $pos = 0;
    my $val = _decode_value(\$text, \$pos);
    return $val;
}

sub _skip_ws {
    my ($t, $p) = @_;
    $$p++ while $$p < length($$t) && substr($$t, $$p, 1) =~ /[\s]/;
}

sub _decode_value {
    my ($t, $p) = @_;
    _skip_ws($t, $p);
    my $c = substr($$t, $$p, 1);
    if ($c eq '{') { return _decode_object($t, $p); }
    if ($c eq '[') { return _decode_array($t, $p); }
    if ($c eq '"') { return _decode_string($t, $p); }
    if (substr($$t, $$p, 4) eq 'true') { $$p += 4; return 1; }
    if (substr($$t, $$p, 5) eq 'false') { $$p += 5; return 0; }
    if (substr($$t, $$p, 4) eq 'null') { $$p += 4; return undef; }
    # number
    if (substr($$t, $$p) =~ /^(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/) {
        $$p += length($1);
        return $1 + 0;
    }
    die "JSON parse error at pos $$p: " . substr($$t, $$p, 30) . "\n";
}

sub _decode_object {
    my ($t, $p) = @_;
    my %h;
    $$p++; # {
    _skip_ws($t, $p);
    if (substr($$t, $$p, 1) eq '}') { $$p++; return \%h; }
    while (1) {
        _skip_ws($t, $p);
        my $key = _decode_string($t, $p);
        _skip_ws($t, $p);
        $$p++; # :
        my $val = _decode_value($t, $p);
        $h{$key} = $val;
        _skip_ws($t, $p);
        my $c = substr($$t, $$p, 1);
        if ($c eq ',') { $$p++; next; }
        if ($c eq '}') { $$p++; last; }
        die "JSON parse error in object at pos $$p\n";
    }
    return \%h;
}

sub _decode_array {
    my ($t, $p) = @_;
    my @a;
    $$p++; # [
    _skip_ws($t, $p);
    if (substr($$t, $$p, 1) eq ']') { $$p++; return \@a; }
    while (1) {
        my $val = _decode_value($t, $p);
        push @a, $val;
        _skip_ws($t, $p);
        my $c = substr($$t, $$p, 1);
        if ($c eq ',') { $$p++; next; }
        if ($c eq ']') { $$p++; last; }
        die "JSON parse error in array at pos $$p\n";
    }
    return \@a;
}

sub _decode_string {
    my ($t, $p) = @_;
    $$p++; # opening "
    my $out = '';
    while (1) {
        my $c = substr($$t, $$p, 1);
        die "unterminated string\n" if $c eq '';
        if ($c eq '"') { $$p++; last; }
        if ($c eq '\\') {
            $$p++;
            my $e = substr($$t, $$p, 1);
            if ($e eq 'n') { $out .= "\n"; }
            elsif ($e eq 't') { $out .= "\t"; }
            elsif ($e eq 'r') { $out .= "\r"; }
            elsif ($e eq 'b') { $out .= "\b"; }
            elsif ($e eq 'f') { $out .= "\f"; }
            elsif ($e eq 'u') {
                my $hex = substr($$t, $$p + 1, 4);
                $out .= chr(hex($hex));
                $$p += 4;
            } else { $out .= $e; }
            $$p++;
        } else {
            $out .= $c;
            $$p++;
        }
    }
    return $out;
}

package main;

# ------------------------------------------------------------------
# curl 呼び出し (新しくビルドしたTLS1.2対応curlを使用)
# ------------------------------------------------------------------
sub call_api {
    # $headers はヘッダー文字列(例 "x-api-key: ...")の配列参照。
    # URL/ヘッダーをプロバイダごとに外から渡す薄いトランスポート層で、
    # このsub自体はAnthropicかGeminiかを一切知らない。
    my ($url, $headers, $body_json) = @_;

    my $tmp_req    = "/tmp/claude-agent-req-$$.json";
    my $tmp_resp   = "/tmp/claude-agent-resp-$$.json";
    my $tmp_config = "/tmp/claude-agent-curlcfg-$$.txt";

    open(my $fh, '>:encoding(UTF-8)', $tmp_req) or die "cannot write $tmp_req: $!\n";
    print $fh $body_json;
    close $fh;

    # APIキーを ps 出力に晒さないよう、コマンドライン引数ではなく
    # curlの設定ファイル(-K)経由でヘッダを渡す
    open(my $cf, '>', $tmp_config) or die "cannot write $tmp_config: $!\n";
    chmod 0600, $tmp_config;
    print $cf qq(url = "$url"\n);
    print $cf qq(request = "POST"\n);
    print $cf qq(cacert = "$CACERT"\n);
    for my $h (@$headers) {
        print $cf qq(header = "$h"\n);
    }
    print $cf qq(data-binary = "\@$tmp_req"\n);
    print $cf qq(output = "$tmp_resp"\n);
    print $cf qq(write-out = "%{http_code}"\n);
    print $cf qq(silent\n);
    print $cf qq(show-error\n);
    close $cf;

    my $http_code = `@{[quote($CURL)]} -K @{[quote($tmp_config)]}`;
    unlink $tmp_req, $tmp_config;

    # STDIN読み込みと同じ理由(冒頭のコメント参照)で、ここも:encoding(UTF-8)
    # 層は使わない。Perl 5.8.6のPerlIO :encoding(UTF-8) は、レスポンスの
    # 中に日本語ファイル名などマルチバイト文字が含まれていると、読み込み
    # バッファの境目でその文字が分割されて "utf8 does not map to Unicode"
    # という警告と文字化けを起こすことがある。生バイトで丸ごと読んでから、
    # 最後にまとめてデコードすることでこれを避ける。
    open(my $rf, '<', $tmp_resp) or die "cannot read response: $!\n";
    local $/;
    my $resp_body_bytes = <$rf>;
    close $rf;
    unlink $tmp_resp;
    my $resp_body = decode('UTF-8', $resp_body_bytes, FB_DEFAULT);

    if ($http_code !~ /^2/) {
        die "API error (HTTP $http_code): $resp_body\n";
    }

    return MiniJSON::decode($resp_body);
}

sub quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# ------------------------------------------------------------------
# プロバイダごとのリクエスト構築・レスポンス解析
#
# 会話履歴(@messages)は常にAnthropicのcontent blocks形式
# (role => user/assistant, content => 文字列 or [{type=>text/tool_use/
# tool_result, ...}, ...]) を内部形式として保持する。Gemini利用時は
# APIを呼ぶ直前にだけこの内部形式をGeminiのcontents/parts形式に変換し、
# 応答が返ってきたらすぐ内部形式に変換し直す。そうすることで、会話ループや
# run_tool などの他のコードは一切プロバイダを意識しなくてよい。
# ------------------------------------------------------------------

sub build_headers {
    if ($PROVIDER eq 'gemini') {
        return [ "x-goog-api-key: $API_KEY", "content-type: application/json" ];
    }
    return [
        "x-api-key: $API_KEY",
        "anthropic-version: $ANTHROPIC_VERSION",
        "content-type: application/json",
    ];
}

sub build_request {
    my ($messages, $tools, $system) = @_;
    return $PROVIDER eq 'gemini'
        ? build_request_gemini($messages, $tools, $system)
        : build_request_anthropic($messages, $tools, $system);
}

sub build_request_anthropic {
    my ($messages, $tools, $system) = @_;
    return {
        model      => $MODEL,
        max_tokens => $MAX_TOKENS,
        system     => $system,
        messages   => $messages,
        tools      => $tools,
    };
}

sub build_request_gemini {
    my ($messages, $tools, $system) = @_;

    my @contents;
    for my $msg (@$messages) {
        my $role = $msg->{role} eq 'assistant' ? 'model' : 'user';
        my @parts;
        if (!ref $msg->{content}) {
            # ユーザーが直接打った、ブロック分割されていない生のテキスト
            push @parts, { text => $msg->{content} };
        }
        else {
            for my $block (@{ $msg->{content} }) {
                if ($block->{type} eq 'text') {
                    my $part = { text => $block->{text} };
                    $part->{thoughtSignature} = $block->{thought_signature} if defined $block->{thought_signature};
                    push @parts, $part;
                }
                elsif ($block->{type} eq 'tool_use') {
                    my $part = { functionCall => { name => $block->{name}, args => $block->{input} } };
                    # Gemini 3系は、functionCallを送り返す時に受け取った時と同じ
                    # thoughtSignatureを付け直さないと400エラーになる(Gemini 2.5
                    # までは無くても動いていたが、3系では必須の検証に変わった)。
                    $part->{thoughtSignature} = $block->{thought_signature} if defined $block->{thought_signature};
                    push @parts, $part;
                }
                elsif ($block->{type} eq 'tool_result') {
                    # Geminiはtool_use_idではなく名前でツール結果を紐付ける
                    push @parts, {
                        functionResponse => {
                            name     => $block->{name},
                            response => { output => $block->{content} },
                        },
                    };
                }
            }
        }
        push @contents, { role => $role, parts => \@parts };
    }

    my @function_declarations = map {
        +{ name => $_->{name}, description => $_->{description}, parameters => $_->{input_schema} }
    } @$tools;

    return {
        contents          => \@contents,
        systemInstruction => { parts => [ { text => $system } ] },
        tools             => [ { functionDeclarations => \@function_declarations } ],
        generationConfig  => {
            maxOutputTokens => $MAX_TOKENS,
            thinkingConfig  => _gemini_thinking_config(),
        },
    };
}

# Gemini 3系は thinkingLevel を省略すると既定で"HIGH"(できる限り深く考える)
# になり、「ビールの主成分は?」のような単純な質問でも最初の1文字が出るまで
# 数十秒かかることがある(実機で確認済み)。この非力なiBook上での対話用途では
# 速さを優先してLOWを既定にし、CLAUDE_GEMINI_THINKING=high で元の挙動に戻せる
# ようにする。Gemini 2.5系はthinkingLevelではなくthinkingBudget(0〜24576、
# -1で動的思考)を使うため、モデル名で分岐する。
sub _gemini_thinking_config {
    my $want_high = lc($ENV{CLAUDE_GEMINI_THINKING} || 'low') eq 'high';
    if ($MODEL =~ /^gemini-3/) {
        return { thinkingLevel => $want_high ? 'HIGH' : 'LOW' };
    }
    return { thinkingBudget => $want_high ? -1 : 0 };
}

sub parse_response {
    my ($resp) = @_;
    return $PROVIDER eq 'gemini'
        ? parse_response_gemini($resp)
        : parse_response_anthropic($resp);
}

sub parse_response_anthropic {
    my ($resp) = @_;
    if ($resp->{type} && $resp->{type} eq 'error') {
        die "APIエラー: " . MiniJSON::encode($resp) . "\n";
    }
    return @{ $resp->{content} || [] };
}

my $gemini_call_seq = 0;

sub parse_response_gemini {
    my ($resp) = @_;
    if ($resp->{error}) {
        die "APIエラー: " . MiniJSON::encode($resp->{error}) . "\n";
    }
    my $candidate = $resp->{candidates} && $resp->{candidates}[0];
    my @blocks;
    for my $part (@{ ($candidate && $candidate->{content}{parts}) || [] }) {
        # Geminiがthinking機能を使っている時、応答の中に「思考の途中経過」を
        # 表す part が混ざって返ってくることがある(thought: trueの印が付く)。
        # これは本来ユーザーに見せる最終回答ではなく内部の下書きなので、
        # このまま素通しすると「クリ→クリー→クリーム→…」のように、考えが
        # 変わるたびに書き直された跡がそのまま画面に出てしまう(実機の
        # PowerBook G4でこの症状が報告され、原因はこれだと判明した)。
        # thoughtSignature(継続のための署名)とは別物なので、こちらは
        # 単純にスキップして最終回答のpartだけを拾う。
        next if $part->{thought};
        if (defined $part->{text}) {
            my $block = { type => 'text', text => $part->{text} };
            $block->{thought_signature} = $part->{thoughtSignature} if defined $part->{thoughtSignature};
            push @blocks, $block;
        }
        elsif ($part->{functionCall}) {
            $gemini_call_seq++;
            my $block = {
                type  => 'tool_use',
                # GeminiのfunctionCallには本来idが無いので、tool_resultを
                # 送り返す時にAnthropic形式の内部表現と揃えるための代用ID
                id    => "gemini-call-$gemini_call_seq",
                name  => $part->{functionCall}{name},
                input => $part->{functionCall}{args} || {},
            };
            # 次のターンでfunctionCallを送り返す時にそのまま付け直す
            # (build_request_geminiの対応するelsif参照)
            $block->{thought_signature} = $part->{thoughtSignature} if defined $part->{thoughtSignature};
            push @blocks, $block;
        }
    }
    return @blocks;
}

# ------------------------------------------------------------------
# ツール定義とツール実行
# ------------------------------------------------------------------
my @TOOLS = (
    {
        name => 'read_file',
        description => 'ファイルの内容を読み取る',
        input_schema => {
            type => 'object',
            properties => { path => { type => 'string', description => '読み取るファイルのパス' } },
            required => ['path'],
        },
    },
    {
        name => 'write_file',
        description => 'ファイルに内容を書き込む(上書き)',
        input_schema => {
            type => 'object',
            properties => {
                path    => { type => 'string', description => '書き込み先のパス' },
                content => { type => 'string', description => '書き込む内容' },
            },
            required => ['path', 'content'],
        },
    },
    {
        name => 'list_dir',
        description => 'ディレクトリの内容を一覧表示する',
        input_schema => {
            type => 'object',
            properties => { path => { type => 'string', description => '一覧表示するディレクトリ(省略時はカレント)' } },
            required => [],
        },
    },
    {
        name => 'run_shell',
        description => 'シェルコマンドを実行し、標準出力/標準エラーを返す',
        input_schema => {
            type => 'object',
            properties => { command => { type => 'string', description => '実行するシェルコマンド' } },
            required => ['command'],
        },
    },
);

sub confirm {
    my ($msg) = @_;
    print "\n[確認] $msg\n実行しますか? [y/N] ";
    my $ans = read_line_interactive('', 0);
    return defined($ans) && $ans =~ /^y/i;
}

# APIキーのような秘密の値を1行、画面に表示せずに読み取る。
# read_line_interactiveと違い矢印キー入力には対応せず(APIキーの貼り付け
# だけを想定)、代わりにEscかCtrl+Cのどちらか1発でその場でundefを返して
# キャンセルできるようにしてある(Escは「未確定の入力を取り消す」の
# 定番、Ctrl+Cは端末での「操作を中断する」の定番 — どちらの習慣の人でも
# 迷わないように両対応)。ここではEscの後に他のバイトが続くかどうかを
# 見ておらず、ESC単体を常にキャンセル扱いにしている — 矢印キーなどの
# ESC始まりのエスケープシーケンスを解釈する必要が無い(単純な1行入力
# しか受け付けない)場面だからこそ成立する簡略化。stty rawモードでは
# ISIGも切れているので、Ctrl+C(0x03)は本物のSIGINTにはならず、ただの
# 1バイトとしてここに届く。
# 戻り値: 入力された文字列(生バイト、改行なし)。キャンセル時はundef。
sub read_secret_or_cancel {
    my ($prompt) = @_;
    print $prompt;

    my $orig_stty = `stty -g`;
    chomp $orig_stty;
    system('stty', 'raw', '-echo', '-opost');

    my $buf = '';
    my $cancelled = 0;
    while (1) {
        my $ch;
        my $n = sysread(STDIN, $ch, 1);
        last unless defined $n && $n > 0;
        my $b = ord($ch);
        if ($b == 0x1b || $b == 0x03) {  # Esc または Ctrl+C -> キャンセル
            $cancelled = 1;
            last;
        }
        elsif ($b == 0x0d || $b == 0x0a) {  # Enter
            last;
        }
        elsif ($b == 0x7f || $b == 0x08) {  # Backspace/Delete
            substr($buf, -1, 1, '') if length($buf) > 0;
        }
        elsif ($b >= 0x20) {
            $buf .= $ch;
        }
        # それ以外の制御バイトは無視
    }

    system('stty', $orig_stty) if defined $orig_stty && $orig_stty ne '';
    print "\n";
    return $cancelled ? undef : $buf;
}

# ------------------------------------------------------------------
# 行編集(矢印キー対応の簡易readline)
#
# 標準の <STDIN> はカーソル移動機能を持たないため、矢印キーを押すと
# ターミナルが送る生のエスケープシーケンス(ESC [ C など)がそのまま
# 文字として画面に出てしまう。これを避けるため、stty で端末をraw
# モードにし、1バイトずつ読みながら簡易的な行編集(←→移動、
# Backspace、↑↓での履歴呼び出し)を自前で実装する。
# 外部CPANモジュール(Term::ReadLineなど)には依存しない。
# ------------------------------------------------------------------
{
    my @HISTORY;

    # デバッグ用: $ENV{CLAUDE_DEBUG_INPUT}にファイルパスを設定すると、
    # read_line_interactiveが実際に受け取った生バイトを1行ずつ追記する。
    # 実機でIME入力時に何が届いているか調べるための一時的な仕組み。
    sub _debug_log {
        return unless $ENV{CLAUDE_DEBUG_INPUT};
        open(my $fh, '>>', $ENV{CLAUDE_DEBUG_INPUT}) or return;
        print $fh @_;
        close $fh;
    }

    # UTF-8の先頭バイトからその文字が何バイトかを返す
    sub _utf8_char_len {
        my ($byte) = @_;
        my $b = ord($byte);
        return 1 if $b < 0x80;
        return 2 if ($b & 0xE0) == 0xC0;
        return 3 if ($b & 0xF0) == 0xE0;
        return 4 if ($b & 0xF8) == 0xF0;
        return 1;  # 不正なバイト列は1バイトずつ進める
    }

    # デコード済みの1文字を受け取り、ターミナル上での表示幅(半角=1/全角=2)を返す
    sub _char_width {
        my ($ch) = @_;
        my $cp = ord($ch);
        return (
            ($cp >= 0x1100 && $cp <= 0x115F) ||
            ($cp >= 0x2E80 && $cp <= 0xA4CF) ||
            ($cp >= 0xAC00 && $cp <= 0xD7A3) ||
            ($cp >= 0xF900 && $cp <= 0xFAFF) ||
            ($cp >= 0xFF00 && $cp <= 0xFF60) ||
            ($cp >= 0xFFE0 && $cp <= 0xFFE6)
        ) ? 2 : 1;
    }

    # デコード済みのPerl文字列を受け取り、ターミナル上での表示幅
    # (半角=1/全角=2)の合計を返す
    sub _display_width_chars {
        my ($text) = @_;
        my $w = 0;
        $w += _char_width($_) for split //, $text;
        return $w;
    }

    # 与えられたUTF-8バイト列の、ターミナル上での表示幅を返す
    sub _display_width {
        my ($bytes) = @_;
        return 0 if $bytes eq '';
        return _display_width_chars(decode('UTF-8', $bytes, FB_DEFAULT));
    }

    # ターミナルの(行数, 桁数)を返す(取得できない、または0の場合はフォールバック)。
    #
    # 一部の環境(実機のPowerMac G4で確認: Mac OS X 10.4.0, ビルド8A428)では
    # `stty size` が正常時でも "0 0" を返すことがある。0を桁数としてそのまま
    # 使うと、_walk_position が常に(0,0)を返すようになり、カーソルを行頭に
    # 固定してしまう(カーソルキーでの編集後、Backspaceが意図と違う文字を
    # 消すバグの原因になっていた)。0以下は無効な値として弾く。
    sub _term_size {
        my $wh = `stty size 2>/dev/null`;
        if ($wh =~ /^\s*(\d+)\s+(\d+)\s*$/ && $2 > 0) {
            my ($rows, $cols) = ($1, $2);
            return ($rows > 0 ? $rows : 24, $cols);
        }
        return (24, 80);
    }

    # カーソルの「今の行番号」(1始まり)を端末に直接問い合わせる(CPR、
    # `\x1b[6n` → 端末が `\x1b[<行>;<列>R` を返す、VT100の頃からある標準機能)。
    # 応答が来ない・壊れた環境(端末が対応していない、標準入力が本物の端末
    # ではない、等)でも固まらないよう、必ずタイムアウト付きで待つ。取得
    # できなければundefを返し、呼び出し側は「分からない」前提で処理を続ける。
    #
    # 重要: この問い合わせの待ち時間中に、ユーザーが実際にキーを押し始める
    # ことがある(前のターンの応答が終わった直後など)。読んだバイトが
    # 「CPR応答の形」と1バイトでも食い違った時点で、そこまで読んだバイトを
    # 全部 $pending_ref に戻す。CPR応答のふりをした本物の入力を誤って
    # 飲み込んでしまわないようにするための、フォーマットの厳密な検証。
    sub _query_cursor_row {
        my ($pending_ref) = @_;
        print "\x1b[6n";
        my $deadline = time() + 0.3;
        my @consumed;

        my $read_raw = sub {
            my $remain = $deadline - time();
            return undef if $remain <= 0;
            my $rin = '';
            vec($rin, fileno(STDIN), 1) = 1;
            my $nfound = select(my $rout = $rin, undef, undef, $remain);
            return undef unless $nfound;
            my $ch;
            my $n = sysread(STDIN, $ch, 1);
            return (defined $n && $n > 0) ? $ch : undef;
        };
        my $give_up = sub {
            unshift @$pending_ref, @consumed;
            return undef;
        };

        my $c = $read_raw->();
        return $give_up->() unless defined $c;
        push @consumed, $c;
        return $give_up->() unless $c eq "\x1b";

        $c = $read_raw->();
        return $give_up->() unless defined $c;
        push @consumed, $c;
        return $give_up->() unless $c eq '[';

        my $row = '';
        while (1) {
            $c = $read_raw->();
            return $give_up->() unless defined $c;
            push @consumed, $c;
            last if $c eq ';';
            return $give_up->() unless $c =~ /[0-9]/;
            $row .= $c;
        }
        return $give_up->() if $row eq '';

        while (1) {
            $c = $read_raw->();
            return $give_up->() unless defined $c;
            push @consumed, $c;
            last if $c eq 'R';
            return $give_up->() unless $c =~ /[0-9]/;
        }

        return $row + 0;
    }

    # _query_cursor_rowと同じだが、列番号も一緒に返す。端末の実際の
    # 行数・桁数をカーソル移動で実測する_probe_terminal_size用。
    sub _query_cursor_pos {
        my ($pending_ref) = @_;
        print "\x1b[6n";
        my $deadline = time() + 0.3;
        my @consumed;

        my $read_raw = sub {
            my $remain = $deadline - time();
            return undef if $remain <= 0;
            my $rin = '';
            vec($rin, fileno(STDIN), 1) = 1;
            my $nfound = select(my $rout = $rin, undef, undef, $remain);
            return undef unless $nfound;
            my $ch;
            my $n = sysread(STDIN, $ch, 1);
            return (defined $n && $n > 0) ? $ch : undef;
        };
        my $give_up = sub {
            unshift @$pending_ref, @consumed;
            return (undef, undef);
        };

        my $c = $read_raw->();
        return $give_up->() unless defined $c;
        push @consumed, $c;
        return $give_up->() unless $c eq "\x1b";

        $c = $read_raw->();
        return $give_up->() unless defined $c;
        push @consumed, $c;
        return $give_up->() unless $c eq '[';

        my $row = '';
        while (1) {
            $c = $read_raw->();
            return $give_up->() unless defined $c;
            push @consumed, $c;
            last if $c eq ';';
            return $give_up->() unless $c =~ /[0-9]/;
            $row .= $c;
        }
        return $give_up->() if $row eq '';

        my $col = '';
        while (1) {
            $c = $read_raw->();
            return $give_up->() unless defined $c;
            push @consumed, $c;
            last if $c eq 'R';
            return $give_up->() unless $c =~ /[0-9]/;
            $col .= $c;
        }
        return $give_up->() if $col eq '';

        return ($row + 0, $col + 0);
    }

    # 端末の本当の行数・桁数を、`stty size`に頼らずカーソル移動+CPRで直接
    # 実測する。PowerMac G4で`stty size`が"0 0"を返す不具合が見つかったのに
    # 続き、実機のPowerBook G4では"0 0"ではなく、実際のウィンドウより明らかに
    # 小さい行数を返す個体があることが実機ログで判明した(44行のウィンドウ
    # なのに32行と判定され、まだ十分余裕があるのに折り返し回避の改行を
    # 早々に挿入してしまっていた)。`stty size`はptyドライバ側の値を返すだけ
    # で、端末エミュレータが実際に表示している行数・桁数とズレることがある。
    # 代わりに、カーソルを画面外の彼方(行999・列999)へ動かしてから位置を
    # 問い合わせると、端末は必ず実際の右下角にクランプする(VT100系の標準
    # 挙動)ので、これで正確な行数・桁数が直接分かる。問い合わせ後は元の
    # 位置へカーソルを戻す。返り値は(実測した行数, 実測した桁数, 最初に
    # 問い合わせた時のカーソル行=$start_row用)。CPR自体に応答がない環境
    # ではいずれもundefを返し、呼び出し側は`stty size`にフォールバックする。
    sub _probe_terminal_size {
        my ($pending_ref) = @_;
        my ($row0, $col0) = _query_cursor_pos($pending_ref);
        _debug_log(sprintf("[probe] initial pos: row=%s col=%s\n",
            defined $row0 ? $row0 : 'undef', defined $col0 ? $col0 : 'undef'));
        return (undef, undef, undef) unless defined $row0;
        # 4桁(9999)だと、実機の一部端末(パラメータの桁数を決め打ちで想定して
        # いる古い実装)でCPRの応答が返って来ない事例が見つかったため、
        # より無難な3桁(500)に下げた。実在するどの端末もまず500行/桁を
        # 超えないので、実測用としては十分すぎる大きさ。
        print "\x1b[500;500H";
        my ($max_row, $max_col) = _query_cursor_pos($pending_ref);
        _debug_log(sprintf("[probe] after CUP 500;500: max_row=%s max_col=%s\n",
            defined $max_row ? $max_row : 'undef', defined $max_col ? $max_col : 'undef'));
        print "\x1b[${row0};${col0}H";
        return (undef, undef, $row0) unless defined $max_row;

        # 実機ログで確認: プロンプトが立て続けに始まる(例えば空Enterの直後に
        # 次の入力が始まる)と、直前の問い合わせの応答がまだ届いている途中
        # だったり、逆に今回の応答がまだ来ていなかったりして、CPRの応答が
        # 前後で混線することがある。この時、厳密な文法チェック自体は通って
        # しまう(ESC [ 数字 ; 数字 R の形にはなっている)せいで、"桁数1"の
        # ようなあり得ない値をそのまま実測結果として採用してしまい、そこから
        # 1文字ごとに折り返し・改行が起きる大惨事になっていた。実在するどんな
        # 端末でも、行数・桁数がこんなに小さいことはまず無いので、明らかに
        # おかしい値は「実測失敗」として扱い、stty sizeへフォールバックする。
        if ($max_row < 3 || $max_col < 10) {
            _debug_log(sprintf("[probe] measured size looks implausible (%dx%d), discarding\n",
                $max_row, $max_col));
            return (undef, undef, $row0);
        }
        return ($max_row, $max_col, $row0);
    }

    # デコード済みの文字列$textを桁数$colsの端末に描画した直後に、
    # カーソルが位置する(0始まりの行, 0始まりの列)を返す。
    #
    # 単純に合計幅を桁数で割るのではなく、1文字ずつ実際に置いていく形で
    # 計算する。全角文字(幅2)が行末にちょうど1マスだけ余っている状態で
    # 現れた場合、実際の端末はその文字を半分だけ描画したりはせず、
    # 丸ごと次の行へ送る(結果、その行の最後の1マスは空白のまま残る)。
    # 合計幅だけを見る計算ではこの「端数」を考慮できず、日本語入力を
    # 続けるうちにズレが蓄積して表示が崩れていくバグの原因になっていた。
    #
    # ターミナルの折り返しは、行末に達しても次の文字が来るまで改行しない
    # "遅延ラップ"仕様のため、ちょうど桁数ぴったりで埋まった場合はその行の
    # 最終列に留まる。
    sub _walk_position {
        my ($text, $cols) = @_;
        return (0, 0) if $cols <= 0;
        my $row = 0;
        my $used = 0;  # 現在の行で使用済みのセル数(0..cols)
        for my $ch (split //, $text) {
            my $w = _char_width($ch);
            if ($used + $w > $cols) {
                $row++;
                $used = 0;
            }
            $used += $w;
        }
        my $col = ($used == $cols) ? $cols - 1 : $used;
        return ($row, $col);
    }

    # プロンプトを表示しつつ1行を対話的に読み込む。矢印キー・Backspace・
    # (use_historyが真なら)↑↓での履歴呼び出しに対応する。
    # 戻り値: 入力された行(生バイト、改行なし)。Ctrl-DでのEOFはundef。
    sub read_line_interactive {
        my ($prompt, $use_history) = @_;
        $use_history = 1 unless defined $use_history;

        my $orig_stty = `stty -g`;
        chomp $orig_stty;
        my ($term_rows, $term_cols) = _term_size();
        # -opostが無いと、環境によっては出力後処理(特にocrnl)が有効なままで
        # 再描画に使う"\r"が改行として扱われ、行を上書きするはずが毎回新しい
        # 行を作ってしまう(結果、入力するたびにどんどん改行されていく)。
        system('stty', 'raw', '-echo', '-opost');

        # 誤って先読みしてしまったバイトを次のループへ戻すためのプッシュバック
        # キュー。マルチバイト文字の続きだと思って読んだバイトが実際には
        # continuationバイトの形式(10xxxxxx)でなかった場合や、下のCPR問い
        # 合わせが実は本物のキー入力だった場合に使う。read_line_interactive
        # の間ずっと使うので、CPR問い合わせより前にここで定義しておく。
        my @pending;

        # 画面の下の方で入力を続けると、再描画そのものが端末を下にスクロール
        # させてしまい、その時々の「打ちかけの状態」が二度と消せないスクロール
        # バック(過去ログ)に焼き付いてしまう(ANSIの画面クリアは今見えている
        # 範囲にしか効かないため)。カーソルの今の行(このプロンプトが始まる
        # 絶対行)をCPRで問い合わせておき、$redraw内で「今回の内容が画面の
        # 最下段を超えそうだ」と分かった、まさにその時だけ改行を差し込んで
        # 避ける(下記$redraw参照)。短い返事がほとんどの通常利用では改行は
        # 一切入らず、実際に長くなった時だけ必要な分だけ余白ができる。CPRに
        # 対応していない/応答がない環境では$start_rowがundefのままになり、
        # この機能は素通りされる(今までの挙動のまま)。
        #
        # ついでに、同じCPRのやり取りを使って$term_rows/$term_colsも
        # `stty size`頼みではなく実測し直す(_probe_terminal_size参照)。
        # 実測できた場合だけ上書きし、できなければ`stty size`ベースの
        # 値のまま(今までの挙動)にフォールバックする。
        my ($probed_rows, $probed_cols, $start_row) = _probe_terminal_size(\@pending);
        if (defined $probed_rows) {
            _debug_log(sprintf("[probe] using measured size: %dx%d (stty said %dx%d)\n",
                $probed_rows, $probed_cols, $term_rows, $term_cols));
            $term_rows = $probed_rows;
            $term_cols = $probed_cols;
        } else {
            _debug_log(sprintf("[probe] measurement failed, falling back to stty size: %dx%d\n",
                $term_rows, $term_cols));
        }

        my $buf = '';                    # 生バイト列
        my $pos = 0;                     # カーソル位置(バイト単位、常に文字境界)
        my $hist_idx = scalar(@HISTORY); # 履歴カーソル(配列末尾 = 新規入力中)
        my $saved_buf = '';              # 履歴を辿る前の入力を退避しておく

        # $promptの先頭改行(例: "\nご用件をどうぞ> ")は最初の表示でだけ使う。
        # 再描画のたびにこれをそのまま含めて出すと、キー入力するたびに
        # 改行が挿入され続けて新しい行がどんどん増えてしまう。
        (my $redraw_prompt = $prompt) =~ s/^\n+//;

        # redraw_promptだけを表示した状態(bufが空)で何行分の表示になるかを初期値とする。
        my $rows_used = (_walk_position($redraw_prompt, $term_cols))[0] + 1;

        # カーソルが「ブロックの先頭から数えて今何行目にいるか」(0始まり)。
        # 左右矢印でカーソルが行の途中(かつ複数行ある場合は別の行)に来ている
        # ことがあるので、$rows_used(ブロック全体の高さ)とは別に必要になる。
        # 初期状態(buf空)ではカーソルは末尾、つまりredraw_promptの最終行にいる。
        my $cursor_display_row = (_walk_position($redraw_prompt, $term_cols))[0];

        my $redraw = sub {
            # $bufは生バイトのUTF-8。STDOUTには:encoding(UTF-8)層が付いているので
            # 一度Perl文字列にデコードしてから渡さないと二重エンコードで文字化けする。
            my $text   = decode('UTF-8', $buf, FB_DEFAULT);
            my $before = decode('UTF-8', substr($buf, 0, $pos), FB_DEFAULT);
            my $full_text   = $redraw_prompt . $text;
            my $full_width  = _display_width_chars($full_text);
            my $cursor_width = _display_width_chars($redraw_prompt . $before);
            my $end_row = (_walk_position($full_text, $term_cols))[0];

            # デバッグ用: 実際に画面へ送るエスケープシーケンスと、その根拠になった
            # 計算結果をそのまま記録する。CLAUDE_DEBUG_INPUT有効時のみ。
            # 「送った内容」と「実際の画面表示」を突き合わせれば、このコードの
            # 計算ミスなのか、端末側がその命令を正しく解釈できていないのかを
            # 切り分けられる。
            _debug_log(sprintf(
                "[redraw] term_cols=%d pos=%d buf_hex=%s rows_used_before=%d full_width=%d cursor_width=%d end_row=%d\n",
                $term_cols, $pos, unpack('H*', $buf), $rows_used, $full_width, $cursor_width, $end_row
            ));

            # 遅延式の画面末尾よけ: 今回の内容が実際に端末の最下段を超えそうに
            # なった、まさにその瞬間だけ改行を差し込んで避ける(毎回先回りで
            # 予約すると、短い返事がほとんどの通常利用でも無駄な空白行が
            # スクロールバックに残ってしまうため)。$start_row(このプロンプトが
            # 始まった絶対行、CPRで取得済み)が分かっている時だけ判定できる。
            if (defined $start_row && $start_row + $end_row >= $term_rows) {
                my $overflow = $start_row + $end_row - $term_rows + 1;
                _debug_log(sprintf("[redraw] lazy headroom: send %d newline(s), start_row was %d\n",
                    $overflow, $start_row));
                print "\n" x $overflow, "\r";

                # 改行を送った時、カーソルが画面の本当の最下段にまだ達して
                # いなければ実際にはスクロールが起きず、ただ1行下に動くだけ
                # で終わる。逆に既に最下段にいれば本当にスクロールし、これ
                # までブロックの上にあった全ての内容(このブロック自身も
                # 含む)の行番号が一斉に若くなる。実機のログでこの2つを
                # 「必ずスクロールしたはず」と決め打ちして計算していたのが
                # 原因の不具合が見つかった(スクロールが起きていないのに
                # 基準行を1つずらしてしまい、次の再描画が本来より1行下に
                # ずれて、古い行が消されずに残ったまま新しい行が重なって
                # 見える)。相対移動(CUU)はスクロールの有無に関係なく必ず
                # 正しく効くので、まず改行前の位置関係で「ブロック先頭のはず」
                # の場所までカーソルを戻し、そこでCPRを使って絶対行を直接
                # 測り直す — 推測ではなく実測に置き換えることで、スクロール
                # した・していない両方のケースを区別なく正しく扱える。
                # 戻る量は$cursor_display_rowだけでなく、たった今下に送った
                # 改行の分($overflow)も足す必要がある。改行前にいた位置
                # (ブロック先頭から$cursor_display_row行目)から、改行で
                # さらに$overflow行下に動いているので、ブロック先頭まで
                # 戻るにはその合計ぶん上に戻らないといけない(ここで
                # $overflowを足し忘れて$cursor_display_rowぶんしか戻らず、
                # 結局ブロック先頭より下でCPRを測ってしまい、かえって
                # 症状が悪化するミスが実際にあった)。
                my $back = $cursor_display_row + $overflow;
                if ($back > 0) {
                    print "\x1b[" . $back . "A";
                }
                my $measured = _query_cursor_row(\@pending);
                if (defined $measured) {
                    $start_row = $measured;
                } else {
                    # CPRが効かない環境向けの最終手段: 従来通りの推測
                    $start_row -= $overflow;
                    $start_row = 1 if $start_row < 1;
                }
                _debug_log(sprintf("[redraw] lazy headroom: start_row now %d (measured=%s)\n",
                    $start_row, defined $measured ? $measured : 'undef'));
                # 既にブロック先頭まで戻ってきているので、この下にある
                # 「ブロック先頭まで戻す」処理を二重に行わないよう印を付ける。
                $cursor_display_row = 0;
            }

            # 前回の再描画で「カーソルが実際にいた行」(ブロック先頭から数えて
            # 何行目か)ぶんだけ戻し、そこから画面末尾までを丸ごとクリアする。
            # 左右矢印で行の途中に戻っていることがあるため、ここは
            # $rows_used(ブロック全体の高さ)ではなく$cursor_display_rowを
            # 使う必要がある — ブロックの高さを使うと、カーソルが先頭寄りの
            # 行にいる時に戻りすぎて、プロンプトより上の会話履歴まで消して
            # しまう(実機のテストで確認したバグ)。最終行だけをクリアする
            # "\r\x1b[K"では前の行が消えずに残って積み重なる、という当初の
            # バグもこのまとめてクリアする方式で防いでいる。
            if ($cursor_display_row > 0) {
                _debug_log(sprintf("[redraw] send: CUU %d\n", $cursor_display_row));
                print "\x1b[" . $cursor_display_row . "A";
            }
            # カーソルが行の途中にある時は、カーソルより後ろの文字列を
            # 反転表示(SGR 7)にする。実機テスト(PowerBook G4)で、矢印キーで
            # カーソルを動かした後に自分が今どこにいるか見失い、意図しない
            # 位置に文字を挿入してしまう事例が見つかったための対策。端末の
            # 点滅カーソルだけでは古い液晶/CRTでは位置が分かりにくいため、
            # 「ここから先が今のカーソルの後ろです」を文字色の反転で明示する。
            # SGR(反転)は幅を持たない制御コードなので、_walk_position等の
            # 桁計算には一切影響しない。
            if ($cursor_width < $full_width) {
                my $after = substr($text, length($before));
                _debug_log(sprintf("[redraw] send: CR + ED0 + text=%s (reverse-video tail after cursor)\n",
                    unpack('H*', encode('UTF-8', $full_text))));
                print "\r\x1b[0J", $redraw_prompt, $before, "\x1b[7m", $after, "\x1b[0m";
            } else {
                _debug_log(sprintf("[redraw] send: CR + ED0 + text=%s\n", unpack('H*', encode('UTF-8', $full_text))));
                print "\r\x1b[0J", $full_text;
            }

            $rows_used = $end_row + 1;
            _debug_log(sprintf("[redraw] rows_used_after=%d\n", $rows_used));

            if ($cursor_width < $full_width) {
                my ($cur_row, $cur_col) = _walk_position($redraw_prompt . $before, $term_cols);
                _debug_log(sprintf("[redraw] cursor not at end: cur_row=%d cur_col=%d\n", $cur_row, $cur_col));
                if ($end_row > $cur_row) {
                    _debug_log(sprintf("[redraw] send: CUU %d\n", $end_row - $cur_row));
                    print "\x1b[" . ($end_row - $cur_row) . "A";
                }
                _debug_log(sprintf("[redraw] send: CHA %d\n", $cur_col + 1));
                print "\x1b[" . ($cur_col + 1) . "G";
                $cursor_display_row = $cur_row;
            } else {
                $cursor_display_row = $end_row;
            }
        };

        print $prompt;
        _debug_log("=== read_line_interactive start ===\n");

        # (プッシュバックキュー@pendingはCPR問い合わせと共有するため、
        # この関数の先頭で既に定義済み)
        my $read_one_byte = sub {
            return shift @pending if @pending;
            my $ch;
            my $n = sysread(STDIN, $ch, 1);
            return (defined $n && $n > 0) ? $ch : undef;
        };
        # Mac OS X Tigerの Terminal.app は、IME(日本語入力など)で確定した
        # テキストを渡す際、各バイトの前に0x16(Ctrl-V。端末で伝統的に
        #「次の1文字をそのまま扱う(LNEXT)」の合図として使われるバイト)を
        # 付けて送ってくることがある。このプログラムはraw modeで自前で
        # 入力を処理しておりLNEXTの解釈をしていないため、何もしないと
        # この合図のバイト自体がゴミとして文字列に混入し、UTF-8が壊れて
        # 文字化けする。ここで0x16を読み飛ばし、次のバイトを本来のデータ
        # として扱う。
        my $read_byte = sub {
            my $ch = $read_one_byte->();
            if (defined $ch && $ch eq "\x16") {
                $ch = $read_one_byte->();
            }
            return $ch;
        };

        my $result;
        RAW_LOOP: while (1) {
            my $ch = $read_byte->();
            if (!defined $ch) {
                _debug_log("EOF\n");
                $result = undef;  # EOF (Ctrl-D)
                last RAW_LOOP;
            }
            my $b = ord($ch);
            _debug_log(sprintf("byte: %02x (%s)\n", $b, ($b >= 0x20 && $b < 0x7f) ? chr($b) : ''));

            if ($b == 13 || $b == 10) {       # Enter
                _debug_log(sprintf("-> ENTER, buf hex=%s\n", unpack('H*', $buf)));
                print "\r\n";
                $result = $buf;
                last RAW_LOOP;
            }
            elsif ($b == 3) {                  # Ctrl-C: 行をキャンセルして空行扱い
                print "\r\n";
                $result = '';
                last RAW_LOOP;
            }
            elsif ($b == 4) {                  # Ctrl-D: 空行ならEOF
                if ($buf eq '') {
                    $result = undef;
                    last RAW_LOOP;
                }
            }
            elsif ($b == 127 || $b == 8) {      # Backspace
                if ($pos > 0) {
                    my $start = $pos - 1;
                    $start-- while $start > 0 && (ord(substr($buf, $start, 1)) & 0xC0) == 0x80;
                    substr($buf, $start, $pos - $start, '');
                    $pos = $start;
                    $redraw->();
                }
            }
            elsif ($b == 27) {                  # ESC: カーソルキーなど
                my $c2 = $read_byte->();
                next RAW_LOOP unless defined $c2;
                if ($c2 eq '[') {
                    my $c3 = $read_byte->();
                    next RAW_LOOP unless defined $c3;
                    if ($c3 eq 'C') {            # →
                        if ($pos < length($buf)) {
                            $pos += _utf8_char_len(substr($buf, $pos, 1));
                            $redraw->();
                        }
                    }
                    elsif ($c3 eq 'D') {         # ←
                        if ($pos > 0) {
                            my $start = $pos - 1;
                            $start-- while $start > 0 && (ord(substr($buf, $start, 1)) & 0xC0) == 0x80;
                            $pos = $start;
                            $redraw->();
                        }
                    }
                    elsif ($use_history && $c3 eq 'A') {  # ↑ 履歴を遡る
                        if ($hist_idx > 0) {
                            $saved_buf = $buf if $hist_idx == @HISTORY;
                            $hist_idx--;
                            $buf = $HISTORY[$hist_idx];
                            $pos = length($buf);
                            $redraw->();
                        }
                    }
                    elsif ($use_history && $c3 eq 'B') {  # ↓ 履歴を進める
                        if ($hist_idx < @HISTORY) {
                            $hist_idx++;
                            $buf = ($hist_idx == @HISTORY) ? $saved_buf : $HISTORY[$hist_idx];
                            $pos = length($buf);
                            $redraw->();
                        }
                    }
                    elsif ($c3 =~ /[0-9;]/) {
                        # ESC [ <数字やセミコロン...> <終端文字> の形。
                        # 数字/セミコロンを終端文字が来るまで集める。
                        my $params = $c3;
                        my $final;
                        while (1) {
                            my $cx = $read_byte->();
                            last unless defined $cx;
                            if ($cx =~ /[0-9;]/) { $params .= $cx; next; }
                            $final = $cx;
                            last;
                        }
                        if (defined $final && $final eq '~' && $params eq '3') {
                            # Delete キー (ESC [ 3 ~)
                            if ($pos < length($buf)) {
                                substr($buf, $pos, _utf8_char_len(substr($buf, $pos, 1)), '');
                                $redraw->();
                            }
                        }
                        # それ以外(特に $final eq 'R' = カーソル位置応答 CPR の
                        # 紛れ込み)は、まるごと読み捨てる。プロンプトが立て続けに
                        # 始まった時などに、こちらが送った位置問い合わせへの
                        # 端末からの遅れた応答("\x1b[32;59R" など)が入力に
                        # 混ざることがあり、以前はその一部("これ;59R"など)が
                        # そのまま文字として行に入っていた。ここで CSI シーケンス
                        # 全体を消費してしまえば、文字化けせず素通りできる。
                        _debug_log(sprintf("[input] swallowed CSI: ESC [ %s %s\n",
                            $params, defined $final ? $final : '(eof)'));
                    }
                }
            }
            else {                               # 通常の文字(UTF-8の生バイト)
                # マルチバイト文字の途中(バイトが揃っていない状態)でredrawすると
                # decode()が不完全な列を「�」に化けさせてしまうため、1文字分の
                # バイトが揃うまで読んでからバッファに追加・再描画する。
                # ただし、続くバイトが本当にUTF-8のcontinuationバイト(10xxxxxx)
                # でなければ、それは別の文字/キーの先頭バイトなので読み戻す
                # (でないと、本来の入力を誤って飲み込んでしまい、以降の入力が
                # 効かなくなってしまう)。
                my $need = _utf8_char_len($ch) - 1;
                my $char = $ch;
                while ($need > 0) {
                    my $cont = $read_byte->();
                    last unless defined $cont;
                    _debug_log(sprintf("  continuation byte: %02x\n", ord($cont)));
                    if ((ord($cont) & 0xC0) != 0x80) {
                        unshift @pending, $cont;
                        last;
                    }
                    $char .= $cont;
                    $need--;
                }
                substr($buf, $pos, 0) = $char;
                $pos += length($char);

                # 速い経路: カーソルが行末(純粋な追記で、途中への挿入では
                # ない)で、かつ今回の1文字では行の折り返しも画面末尾よけの
                # 改行挿入も起きないと分かっている時は、行全体を消して描き
                # 直すのではなく、その1文字だけをそのまま print する。
                # 毎キーストロークで全再描画すると、遅い実機では入力のたびに
                # 目の前の行が一瞬で総書き換えされてチラつき、どこを読めば
                # いいのか・カーソルがどこかを見失う原因になる(実機の
                # PowerBook G4で報告された)。折り返し・挿入・矢印・履歴・
                # Backspace など、位置がずれる操作の時だけ従来通り $redraw
                # する。
                my $fast = 0;
                if ($pos == length($buf)) {
                    my $new_full = $redraw_prompt . decode('UTF-8', $buf, FB_DEFAULT);
                    my ($nr, $nc) = _walk_position($new_full, $term_cols);
                    if ($nr == $rows_used - 1                    # 行数が増えない
                        && $nc <= $term_cols - 2                 # 折り返し待ちにならない
                        && !(defined $start_row
                             && $start_row + $nr >= $term_rows)) # 画面末尾よけ不要
                    {
                        print decode('UTF-8', $char, FB_DEFAULT);
                        $cursor_display_row = $nr;
                        _debug_log(sprintf("[fast] append 1 char, pos=%d nc=%d\n", $pos, $nc));
                        $fast = 1;
                    }
                }
                $redraw->() unless $fast;
            }
        }

        system('stty', $orig_stty) if defined $orig_stty && $orig_stty ne '';

        if ($use_history && defined $result && $result ne '') {
            push @HISTORY, $result;
        }
        return $result;
    }
}

sub run_tool {
    my ($name, $input) = @_;

    if ($name eq 'read_file') {
        my $path = $input->{path};
        open(my $fh, '<:encoding(UTF-8)', $path) or return "エラー: $path を開けません: $!";
        local $/;
        my $content = <$fh>;
        close $fh;
        return $content;
    }
    elsif ($name eq 'write_file') {
        my $path = $input->{path};
        unless (confirm("ファイル '$path' に書き込みます")) {
            return "ユーザーが書き込みをキャンセルしました";
        }
        open(my $fh, '>:encoding(UTF-8)', $path) or return "エラー: $path に書き込めません: $!";
        print $fh $input->{content};
        close $fh;
        return "書き込み完了: $path";
    }
    elsif ($name eq 'list_dir') {
        my $path = $input->{path} || '.';
        opendir(my $dh, $path) or return "エラー: $path を開けません: $!";
        my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir $dh;
        return join("\n", @entries);
    }
    elsif ($name eq 'run_shell') {
        my $command = $input->{command};
        unless (confirm("コマンドを実行します: $command")) {
            return "ユーザーが実行をキャンセルしました";
        }
        my $output = `$command 2>&1`;
        return $output eq '' ? '(出力なし)' : $output;
    }
    else {
        return "不明なツール: $name";
    }
}

# ------------------------------------------------------------------
# 会話ループ
# ------------------------------------------------------------------
my @messages;

print "=== iBook G4 Advisor ===\n";
print "[$PROVIDER / $MODEL]\n";
print "こんにちは。(終了は 'exit' または Ctrl-D。AI切り替えは /claude か /gemini)\n";

while (1) {
    my $input = read_line_interactive("\nご用件をどうぞ> ");
    last unless defined $input;
    # 行全体(生バイト)が揃ってから、まとめてUTF-8デコードする
    $input = decode('UTF-8', $input, FB_DEFAULT);
    next if $input eq '';
    last if $input eq 'exit';

    if ($input eq '/claude' || $input eq '/gemini') {
        my $target = $input eq '/claude' ? 'anthropic' : 'gemini';
        if ($target eq $PROVIDER) {
            print "\nすでに [$PROVIDER / $MODEL] です。\n";
        }
        else {
            eval { configure_provider($target) };
            if ($@) {
                # キーが無くて切り替えられない場合、その場で入力してもらう。
                # EscかCtrl+Cでキャンセルすれば今までどおり元のプロバイダのまま続けられる。
                my $key_name = $target eq 'gemini' ? 'GEMINI_API_KEY' : 'ANTHROPIC_API_KEY';
                my $key = read_secret_or_cancel("\n$key_name がまだ設定されていません。入力してください(Escまたは Ctrl+Cでキャンセル)\n> ");
                if (!defined $key || $key eq '') {
                    print "\nキャンセルしました。[$PROVIDER / $MODEL] のままです。\n";
                }
                else {
                    $ENV{$key_name} = $key;
                    eval { configure_provider($target) };
                    if ($@) {
                        print "\nそれでも切り替えられませんでした: $@";
                    }
                    else {
                        print "\n[$PROVIDER / $MODEL] に切り替えました。ここまでの会話はそのまま引き継がれます。\n";
                        if (confirm("このキーを $ENV_FILE_PATH に保存して、次回から入力せずに使えるようにしますか")) {
                            if (open(my $ef, '>>', $ENV_FILE_PATH)) {
                                print $ef "export $key_name=$key\n";
                                close $ef;
                                chmod 0600, $ENV_FILE_PATH;
                                print "保存しました。\n";
                            }
                            else {
                                print "保存に失敗しました($ENV_FILE_PATH に書き込めません)。\n";
                            }
                        }
                    }
                }
            }
            else {
                print "\n[$PROVIDER / $MODEL] に切り替えました。ここまでの会話はそのまま引き継がれます。\n";
            }
        }
        next;
    }

    push @messages, { role => 'user', content => $input };

    while (1) {
        my $body = build_request(\@messages, \@TOOLS, $SYSTEM_PROMPT);
        my $resp = call_api($API_URL, build_headers(), MiniJSON::encode($body));

        my @content_blocks = eval { parse_response($resp) };
        if ($@) {
            print $@;
            last;
        }
        push @messages, { role => 'assistant', content => \@content_blocks };

        my @tool_results;
        for my $block (@content_blocks) {
            if ($block->{type} eq 'text') {
                print "\nclaude> $block->{text}\n";
            }
            elsif ($block->{type} eq 'tool_use') {
                print "\n[tool_use] $block->{name}(" . MiniJSON::encode($block->{input}) . ")\n";
                my $result = run_tool($block->{name}, $block->{input});
                push @tool_results, {
                    type => 'tool_result',
                    tool_use_id => $block->{id},
                    name => $block->{name},
                    content => $result,
                };
            }
        }

        if (@tool_results) {
            push @messages, { role => 'user', content => \@tool_results };
            next; # ツール結果を送ってもう一度APIを呼ぶ
        }

        last; # tool_useが無ければこのターンは終了
    }
}

print "\nさようなら。\n";
