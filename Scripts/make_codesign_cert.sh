#!/bin/bash
# 로컬 전용 자체 서명 코드 서명 인증서를 만들어 로그인 키체인에 등록한다.
# 이 인증서로 서명하면 앱의 서명 정체성(designated requirement)이 빌드마다 동일하게 유지되어,
# 전체 디스크 접근 권한(TCC) 등을 한 번만 부여해도 재빌드 후 계속 유지된다.
set -euo pipefail

CERT_NAME="XFinder Self Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> 이미 '$CERT_NAME' 인증서가 있습니다. 재생성을 건너뜁니다."
    exit 0
fi

echo "==> OpenSSL 설정 작성"
cat > "$TMP/codesign.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = XFinder Self Signed
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> 키 + 자체 서명 인증서 생성 (유효기간 10년)"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/codesign.cnf" >/dev/null 2>&1

echo "==> PKCS#12 묶음 생성 (macOS 호환 레거시 알고리즘)"
# OpenSSL 3.x 기본 PKCS#12는 Apple Security가 못 읽으므로 -legacy + SHA1-3DES 사용.
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/bundle.p12" -passout pass:xfinder -name "$CERT_NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "==> 로그인 키체인에 가져오기 (codesign이 사용하도록 허용)"
security import "$TMP/bundle.p12" -k "$KEYCHAIN" -P xfinder -T /usr/bin/codesign -A

echo "==> 코드 서명 신뢰 설정"
# 로그인 키체인 범위에서 코드 서명용으로 신뢰 설정(관리자 권한 불필요).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || \
    echo "   (신뢰 설정은 건너뜀 — 서명에는 영향 없음)"

echo "==> 확인"
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo "==> 완료: '$CERT_NAME' 등록됨"
