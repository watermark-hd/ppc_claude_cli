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
use Encode qw(decode FB_DEFAULT);

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
my $API_KEY   = $ENV{ANTHROPIC_API_KEY} or die "ANTHROPIC_API_KEY を設定してください\n";
my $MODEL     = $ENV{CLAUDE_MODEL} || 'claude-sonnet-4-5-20250929';
my $MAX_TOKENS = 4096;
my $API_URL   = 'https://api.anthropic.com/v1/messages';
my $ANTHROPIC_VERSION = '2023-06-01';

my $SYSTEM_PROMPT = <<'EOS';
You are a lightweight coding assistant running in the terminal of a
PowerPC iBook G4 (Mac OS X 10.4 Tiger). You have four tools available:
read_file, write_file, list_dir, and run_shell. Use them to read/write
files and run commands in the user's working directory. Keep replies
concise, and always reply in the same language the user wrote in
(if they write in Japanese, reply in Japanese; if English, reply in
English; and so on for other languages).
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
    my ($body_json) = @_;

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
    print $cf qq(url = "$API_URL"\n);
    print $cf qq(request = "POST"\n);
    print $cf qq(cacert = "$CACERT"\n);
    print $cf qq(header = "x-api-key: $API_KEY"\n);
    print $cf qq(header = "anthropic-version: $ANTHROPIC_VERSION"\n);
    print $cf qq(header = "content-type: application/json"\n);
    print $cf qq(data-binary = "\@$tmp_req"\n);
    print $cf qq(output = "$tmp_resp"\n);
    print $cf qq(write-out = "%{http_code}"\n);
    print $cf qq(silent\n);
    print $cf qq(show-error\n);
    close $cf;

    my $http_code = `@{[quote($CURL)]} -K @{[quote($tmp_config)]}`;
    unlink $tmp_req, $tmp_config;

    open(my $rf, '<:encoding(UTF-8)', $tmp_resp) or die "cannot read response: $!\n";
    local $/;
    my $resp_body = <$rf>;
    close $rf;
    unlink $tmp_resp;

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

    # 与えられたUTF-8バイト列の、ターミナル上での表示幅(半角=1/全角=2)を返す
    sub _display_width {
        my ($bytes) = @_;
        return 0 if $bytes eq '';
        my $text = decode('UTF-8', $bytes, FB_DEFAULT);
        my $w = 0;
        for my $ch (split //, $text) {
            my $cp = ord($ch);
            $w += (
                ($cp >= 0x1100 && $cp <= 0x115F) ||
                ($cp >= 0x2E80 && $cp <= 0xA4CF) ||
                ($cp >= 0xAC00 && $cp <= 0xD7A3) ||
                ($cp >= 0xF900 && $cp <= 0xFAFF) ||
                ($cp >= 0xFF00 && $cp <= 0xFF60) ||
                ($cp >= 0xFFE0 && $cp <= 0xFFE6)
            ) ? 2 : 1;
        }
        return $w;
    }

    # プロンプトを表示しつつ1行を対話的に読み込む。矢印キー・Backspace・
    # (use_historyが真なら)↑↓での履歴呼び出しに対応する。
    # 戻り値: 入力された行(生バイト、改行なし)。Ctrl-DでのEOFはundef。
    sub read_line_interactive {
        my ($prompt, $use_history) = @_;
        $use_history = 1 unless defined $use_history;

        my $orig_stty = `stty -g`;
        chomp $orig_stty;
        # -opostが無いと、環境によっては出力後処理(特にocrnl)が有効なままで
        # 再描画に使う"\r"が改行として扱われ、行を上書きするはずが毎回新しい
        # 行を作ってしまう(結果、入力するたびにどんどん改行されていく)。
        system('stty', 'raw', '-echo', '-opost');

        my $buf = '';                    # 生バイト列
        my $pos = 0;                     # カーソル位置(バイト単位、常に文字境界)
        my $hist_idx = scalar(@HISTORY); # 履歴カーソル(配列末尾 = 新規入力中)
        my $saved_buf = '';              # 履歴を辿る前の入力を退避しておく

        my $redraw = sub {
            # $bufは生バイトのUTF-8。STDOUTには:encoding(UTF-8)層が付いているので
            # 一度Perl文字列にデコードしてから渡さないと二重エンコードで文字化けする。
            print "\r\x1b[K", $prompt, decode('UTF-8', $buf, FB_DEFAULT);
            my $w = _display_width(substr($buf, $pos));
            print "\x1b[${w}D" if $w > 0;
        };

        print $prompt;

        my $result;
        RAW_LOOP: while (1) {
            my $ch;
            my $n = sysread(STDIN, $ch, 1);
            if (!defined $n || $n == 0) {
                $result = undef;  # EOF (Ctrl-D)
                last RAW_LOOP;
            }
            my $b = ord($ch);

            if ($b == 13 || $b == 10) {       # Enter
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
                my $n2 = sysread(STDIN, my $c2, 1);
                next RAW_LOOP unless $n2;
                if ($c2 eq '[') {
                    my $n3 = sysread(STDIN, my $c3, 1);
                    next RAW_LOOP unless $n3;
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
                    elsif ($c3 eq '3') {         # Delete キー (ESC [ 3 ~)
                        my $n4 = sysread(STDIN, my $c4, 1);
                        if ($n4 && $pos < length($buf)) {
                            substr($buf, $pos, _utf8_char_len(substr($buf, $pos, 1)), '');
                            $redraw->();
                        }
                    }
                }
            }
            else {                               # 通常の文字(UTF-8の生バイト)
                # マルチバイト文字の途中(バイトが揃っていない状態)でredrawすると
                # decode()が不完全な列を「�」に化けさせてしまうため、1文字分の
                # バイトが揃うまで読んでからバッファに追加・再描画する。
                my $need = _utf8_char_len($ch) - 1;
                my $char = $ch;
                while ($need > 0) {
                    my $n2 = sysread(STDIN, my $cont, 1);
                    last unless $n2;
                    $char .= $cont;
                    $need--;
                }
                substr($buf, $pos, 0) = $char;
                $pos += length($char);
                $redraw->();
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

print "=== iBook G4 Claude Agent ===\n";
print "こんにちは。(終了は 'exit' または Ctrl-D)\n";

while (1) {
    my $input = read_line_interactive("\nご用件をどうぞ> ");
    last unless defined $input;
    # 行全体(生バイト)が揃ってから、まとめてUTF-8デコードする
    $input = decode('UTF-8', $input, FB_DEFAULT);
    next if $input eq '';
    last if $input eq 'exit';

    push @messages, { role => 'user', content => $input };

    while (1) {
        my $body = {
            model => $MODEL,
            max_tokens => $MAX_TOKENS,
            system => $SYSTEM_PROMPT,
            messages => \@messages,
            tools => \@TOOLS,
        };
        my $resp = call_api(MiniJSON::encode($body));

        if ($resp->{type} && $resp->{type} eq 'error') {
            print "APIエラー: " . MiniJSON::encode($resp) . "\n";
            last;
        }

        my @content_blocks = @{ $resp->{content} || [] };
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
