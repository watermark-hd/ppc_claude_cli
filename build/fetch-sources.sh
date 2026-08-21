#!/bin/bash
# モダンな端末(TLS1.2が使える環境)で実行し、OpenSSL/curlのソースと
# 最新のCA証明書バンドルを取得する。iBook自身はHTTPS/gitが使えないため、
# ここで取得したファイルを scp で iBook へ転送する。
set -e

DIST_DIR="$(cd "$(dirname "$0")/.." && pwd)/dist"
mkdir -p "$DIST_DIR"
cd "$DIST_DIR"

OPENSSL_VERSION=1.0.2u
CURL_VERSION=8.10.1

echo "=== OpenSSL ${OPENSSL_VERSION} ==="
curl -fsSL -o "openssl-${OPENSSL_VERSION}.tar.gz" \
  "https://www.openssl.org/source/old/1.0.2/openssl-${OPENSSL_VERSION}.tar.gz"
EXPECTED_SHA=$(curl -fsSL "https://www.openssl.org/source/old/1.0.2/openssl-${OPENSSL_VERSION}.tar.gz.sha256")
ACTUAL_SHA=$(shasum -a 256 "openssl-${OPENSSL_VERSION}.tar.gz" | awk '{print $1}')
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  echo "OpenSSL checksum mismatch!" >&2
  exit 1
fi
echo "OpenSSL checksum OK: $ACTUAL_SHA"

echo "=== curl ${CURL_VERSION} ==="
curl -fsSL -o curl.tar.gz "https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
echo "curl sha256: $(shasum -a 256 curl.tar.gz | awk '{print $1}')"
echo "(curl.seの公開PGP署名と突き合わせたい場合は curl-${CURL_VERSION}.tar.gz.asc も別途取得してください)"

echo "=== cacert.pem (Mozilla CA bundle, curl.se配布) ==="
curl -fsSL -o cacert.pem https://curl.se/ca/cacert.pem
echo "$(wc -l < cacert.pem) lines"

echo "=== 完了 ==="
ls -la "$DIST_DIR"
echo "次: scp \"$DIST_DIR\"/{openssl-${OPENSSL_VERSION}.tar.gz,curl.tar.gz,cacert.pem} ibook:~/claude-build/src/"
