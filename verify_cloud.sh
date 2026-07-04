#!/system/bin/sh
# verify_cloud.sh — проверка слоя эмуляции облака.
# Запускать: adb shell sh /data/verify_cloud.sh

BB=/data/busybox
DEBIAN=/data/debian
CLOUD=$DEBIAN/opt/cloud

echo "=== ALYT Cloud Emulator Status ==="

check() {
    if [ -e "$2" ]; then echo "  [OK] $1"; else echo "  [!!] $1 — НЕТ: $2"; fi
}

echo ""
echo "--- Файлы эмулятора (в chroot) ---"
check "httpproxy.py"       $CLOUD/httpproxy.py
check "tlsproxy.py"        $CLOUD/tlsproxy.py
check "openssl_legacy.cnf" $CLOUD/openssl_legacy.cnf
check "server.pem"         $CLOUD/server.pem
check "ca.crt"             $CLOUD/ca.crt

echo ""
echo "--- /system (переживает reset) ---"
check "cloud_autostart.sh" /system/bin/cloud_autostart.sh
CA_HASH=$($BB cat $CLOUD/ca_hash.txt 2>/dev/null)
if [ -n "$CA_HASH" ]; then
    check "CA в cacerts ($CA_HASH.0)" /system/etc/security/cacerts/${CA_HASH}.0
fi

echo ""
echo "--- hosts-редирект ---"
if $BB grep -q "hub2.lifecontrol.ru" /system/etc/hosts; then
    echo "  [OK] hub2.lifecontrol.ru → 127.0.0.1"
else
    echo "  [!!] hosts-редирект отсутствует"
fi

echo ""
echo "--- Слушающие порты ---"
# 443 = 01BB, 6666 = 1A0A
if $BB cat /proc/net/tcp6 2>/dev/null | $BB grep -q ":01BB"; then
    echo "  [OK] TLS 443 слушает"
else
    echo "  [!!] TLS 443 НЕ слушает"
fi
if $BB cat /proc/net/tcp 2>/dev/null | $BB grep -q "00000000:1A0A"; then
    echo "  [OK] HTTP 6666 слушает"
else
    echo "  [!!] HTTP 6666 НЕ слушает"
fi

echo ""
echo "--- iptables редиректы ---"
/system/bin/iptables -t nat -L OUTPUT -n 2>/dev/null | $BB grep -q "95.163.244.135" \
    && echo "  [OK] редирект на 95.163.244.135 активен" \
    || echo "  [!!] iptables редирект отсутствует"

echo ""
echo "--- Живой тест HTTPS ---"
R=$($BB wget -q -T 5 -O- --no-check-certificate --post-data='x=1' \
    "https://127.0.0.1/ServerLYT/LYT_Server/LYT_Login.php" \
    --header="Host: hub2.lifecontrol.ru" 2>/dev/null)
if echo "$R" | $BB grep -q "success"; then
    echo "  [OK] LYT_Login → $R"
else
    echo "  [!!] HTTPS не отвечает (получено: '$R')"
fi

echo ""
echo "--- БД регистрации ---"
LYTDB=/data/data/it.takeoff.lytcentral/databases/LYT_ServerDataDb
if [ -f "$LYTDB" ]; then
    REG=$($BB strings "$LYTDB" 2>/dev/null | $BB grep -o "mes2[01]" | $BB tail -1)
    echo "  RegStatus маркер: $REG (mes21 = зарегистрирован)"
else
    echo "  [!!] БД не найдена"
fi

echo ""
echo "--- setCloudStatus (последнее) ---"
logcat -d 2>/dev/null | $BB grep "setCloudStatus" | $BB tail -n 3

echo ""
echo "=== Конец проверки ==="
