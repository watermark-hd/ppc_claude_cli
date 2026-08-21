#!/bin/bash
# iBook G4 (Tiger/PPC) 上で実行する curl ビルドスクリプト
# 直前にビルドした ~/claude-toolchain の OpenSSL をリンクする
set -e

PREFIX="$HOME/claude-toolchain"
SRC=~/claude-build/src

cd ~/claude-build
tar xzf "$SRC/curl.tar.gz"
cd curl-*/

# 重要: Mac OS X (Darwin) の ld はデフォルトで /usr/lib 等システムパスの
# .dylib を、-L で指定した独自prefixの .a より優先して選んでしまうことがある。
# Tiger標準の /usr/lib/libssl.dylib (OpenSSL 0.9.7l) を掴んでしまい、
# TLS1.2どころか一部シンボル不足でリンクエラーになるため、
# -Wl,-search_paths_first で「-L で指定したパスを素直に順番通り探す」
# 挙動を明示的に強制する。
export LDFLAGS="-L$PREFIX/lib -Wl,-search_paths_first"

./configure \
  --prefix="$PREFIX" \
  --with-ssl="$PREFIX" \
  --disable-shared \
  --enable-static \
  --without-libpsl \
  --without-brotli \
  --without-zstd \
  --without-nghttp2 \
  --without-nghttp3 \
  --disable-ldap \
  --disable-ldaps

make LDFLAGS="$LDFLAGS -framework CoreFoundation -framework CoreServices -framework SystemConfiguration"

make install LDFLAGS="$LDFLAGS -framework CoreFoundation -framework CoreServices -framework SystemConfiguration"

echo "=== DONE ==="
"$PREFIX/bin/curl" --version
