#!/bin/bash
# iBook G4 (Tiger/PPC) 上で実行する OpenSSL 1.0.2u ビルドスクリプト
# システムのopensslは触らず /usr/local/claude-toolchain に隔離インストールする
set -e

PREFIX="$HOME/claude-toolchain"
SRC=~/claude-build/src
BUILD=~/claude-build/openssl-1.0.2u

mkdir -p "$BUILD"
cd ~/claude-build
tar xzf "$SRC/openssl-1.0.2u.tar.gz"
cd openssl-1.0.2u

# PPC G4 + gcc4.0.0でのビルドはasm最適化を切って安全側に倒す。
# staticライブラリのみ生成する(sharedにするとdylibのinstall_nameに
# Configure時点のprefixが焼き込まれ、後でprefixを変更すると
# 実行時に "Library not loaded" で壊れるため)。
./Configure darwin-ppc-cc no-asm no-shared --prefix="$PREFIX" --openssldir="$PREFIX/ssl"

# Tiger標準のDeveloper Toolsにはmakedependが無く `make depend` は失敗するため
# (ヘッダ依存関係の追跡は一度きりのビルドには不要)、依存追跡なしで直接ビルドする
make

mkdir -p "$PREFIX"
make install

echo "=== DONE ==="
"$PREFIX/bin/openssl" version
