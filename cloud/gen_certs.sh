#!/bin/bash
# gen_certs.sh - generate CA + server cert for the cloud emulator.
# Runs INSIDE chroot (openssl 1.1.1 present).
#
# Output:
#   /opt/cloud/ca.crt        - CA (public), installed into Android cacerts
#   /opt/cloud/ca.key        - CA private key (do NOT commit to public repo)
#   /opt/cloud/server.pem    - cert+key for tlsproxy.py
#   /opt/cloud/ca_hash.txt   - subject_hash_old, filename for Android cacerts
#
# Idempotent: reuses CA if ca.crt exists, only rebuilds server.pem
# (so the Android cacerts hash stays stable across bootstrap runs).

set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_PRELOAD=""

DIR=/opt/cloud
mkdir -p "$DIR"
cd "$DIR"

SAN="DNS:hub2.lifecontrol.ru,DNS:lk2.lifecontrol.ru,DNS:lifecontrol.ru"

# --- CA (create once) ---
if [ ! -f "$DIR/ca.crt" ] || [ ! -f "$DIR/ca.key" ]; then
    echo "gen_certs: creating CA..."
    openssl genrsa -out "$DIR/ca.key" 2048
    openssl req -new -x509 -days 3650 -key "$DIR/ca.key" -out "$DIR/ca.crt" \
        -subj "/CN=LocalCA-ALYT"
else
    echo "gen_certs: CA exists, reusing"
fi

# --- Server cert (signed by our CA) ---
echo "gen_certs: creating server cert..."
openssl genrsa -out "$DIR/server.key" 2048
openssl req -new -key "$DIR/server.key" -out "$DIR/server.csr" \
    -subj "/CN=hub2.lifecontrol.ru"
cat > "$DIR/ext.cnf" <<EOF
subjectAltName=$SAN
EOF
openssl x509 -req -days 3650 -in "$DIR/server.csr" \
    -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
    -extfile "$DIR/ext.cnf" -out "$DIR/server.crt"

# tlsproxy.py wants cert+key in one file
cat "$DIR/server.crt" "$DIR/server.key" > "$DIR/server.pem"

# --- Hash for Android cacerts (filename XXXXXXXX.0) ---
HASH=$(openssl x509 -in "$DIR/ca.crt" -subject_hash_old -noout)
echo "$HASH" > "$DIR/ca_hash.txt"
cp "$DIR/ca.crt" "$DIR/${HASH}.0"

echo "gen_certs: done."
echo "  CA hash: $HASH  (file ${HASH}.0 -> /system/etc/security/cacerts/)"
echo "  server.pem: $DIR/server.pem"