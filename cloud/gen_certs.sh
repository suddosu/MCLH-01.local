#!/bin/bash
# gen_certs.sh — генерация CA и серверного сертификата для эмулятора облака.
# Запускается ВНУТРИ chroot (там есть openssl 1.1.1).
#
# Результат:
#   /opt/cloud/ca.crt        — CA (публичный), ставится в Android cacerts
#   /opt/cloud/ca.key        — приватный ключ CA (НЕ коммитить в public repo)
#   /opt/cloud/server.pem    — cert+key для tlsproxy.py
#   /opt/cloud/ca_hash.txt   — subject_hash_old, имя файла для Android cacerts
#
# Идемпотентно: если ca.crt уже есть — переиспользует CA, пересобирает
# только server.pem (чтобы hash в Android cacerts не менялся между
# запусками bootstrap).

set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_PRELOAD=""

DIR=/opt/cloud
mkdir -p "$DIR"
cd "$DIR"

# SAN — все имена, на которые ходит приложение
SAN="DNS:hub2.lifecontrol.ru,DNS:lk2.lifecontrol.ru,DNS:lifecontrol.ru"

# --- CA (создаём один раз) ---
if [ ! -f "$DIR/ca.crt" ] || [ ! -f "$DIR/ca.key" ]; then
    echo "gen_certs: создаём CA..."
    openssl genrsa -out "$DIR/ca.key" 2048
    openssl req -new -x509 -days 3650 \
        -key "$DIR/ca.key" \
        -out "$DIR/ca.crt" \
        -subj "/CN=LocalCA-ALYT"
else
    echo "gen_certs: CA уже существует, переиспользуем"
fi

# --- Серверный сертификат (подписанный нашим CA) ---
echo "gen_certs: создаём серверный сертификат..."
openssl genrsa -out "$DIR/server.key" 2048
openssl req -new \
    -key "$DIR/server.key" \
    -out "$DIR/server.csr" \
    -subj "/CN=hub2.lifecontrol.ru"

cat > "$DIR/ext.cnf" <<EOF
subjectAltName=$SAN
EOF

openssl x509 -req -days 3650 \
    -in "$DIR/server.csr" \
    -CA "$DIR/ca.crt" \
    -CAkey "$DIR/ca.key" \
    -CAcreateserial \
    -extfile "$DIR/ext.cnf" \
    -out "$DIR/server.crt"

# tlsproxy.py ждёт cert+key в одном файле
cat "$DIR/server.crt" "$DIR/server.key" > "$DIR/server.pem"

# --- Hash для Android cacerts (имя файла XXXXXXXX.0) ---
HASH=$(openssl x509 -in "$DIR/ca.crt" -subject_hash_old -noout)
echo "$HASH" > "$DIR/ca_hash.txt"

# Android хранилищу нужен PEM с определённым форматом имени
cp "$DIR/ca.crt" "$DIR/${HASH}.0"

echo "gen_certs: готово."
echo "  CA hash: $HASH  (файл ${HASH}.0 → /system/etc/security/cacerts/)"
echo "  server.pem: $DIR/server.pem"
