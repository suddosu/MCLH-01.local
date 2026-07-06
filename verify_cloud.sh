#!/system/bin/sh
# verify_cloud.sh - check the cloud-emulation layer.
# Run: sh /data/verify_cloud.sh

BB=/data/busybox
DEBIAN=/data/debian
CLOUD=$DEBIAN/opt/cloud

echo "=== ALYT Cloud Emulator Status ==="

check() { if [ -e "$2" ]; then echo "  [OK] $1"; else echo "  [!!] $1 - MISSING: $2"; fi; }

echo ""
echo "--- Emulator files (in chroot) ---"
check "httpproxy.py"       $CLOUD/httpproxy.py
check "tlsproxy.py"        $CLOUD/tlsproxy.py
check "openssl_legacy.cnf" $CLOUD/openssl_legacy.cnf
check "server.pem"         $CLOUD/server.pem
check "ca.crt"             $CLOUD/ca.crt

echo ""
echo "--- /system (survives reset) ---"
check "cloud_autostart.sh" /system/bin/cloud_autostart.sh
CA_HASH=$($BB cat $CLOUD/ca_hash.txt 2>/dev/null)
[ -n "$CA_HASH" ] && check "CA in cacerts ($CA_HASH.0)" /system/etc/security/cacerts/${CA_HASH}.0

echo ""
echo "--- hosts redirect ---"
if $BB grep -q "hub2.lifecontrol.ru" /system/etc/hosts; then
    echo "  [OK] hub2.lifecontrol.ru -> 127.0.0.1"
else
    echo "  [!!] hosts redirect missing"
fi

echo ""
echo "--- Listening ports ---"
# 443 = 01BB, 6666 = 1A0A
if $BB cat /proc/net/tcp6 2>/dev/null | $BB grep -q ":01BB"; then
    echo "  [OK] TLS 443 listening"
else
    echo "  [!!] TLS 443 NOT listening"
fi
if $BB cat /proc/net/tcp 2>/dev/null | $BB grep -q "00000000:1A0A"; then
    echo "  [OK] HTTP 6666 listening"
else
    echo "  [!!] HTTP 6666 NOT listening"
fi

echo ""
echo "--- iptables redirect ---"
/system/bin/iptables -t nat -L OUTPUT -n 2>/dev/null | $BB grep -q "95.163.244.135" \
    && echo "  [OK] redirect to 95.163.244.135 active" \
    || echo "  [!!] iptables redirect missing"

echo ""
echo "--- Live HTTPS test ---"
R=$($BB wget -q -T 5 -O- --no-check-certificate --post-data='x=1' \
    "https://127.0.0.1/ServerLYT/LYT_Server/LYT_Login.php" \
    --header="Host: hub2.lifecontrol.ru" 2>/dev/null)
if echo "$R" | $BB grep -q "success"; then
    echo "  [OK] LYT_Login -> $R"
else
    echo "  [!!] HTTPS not responding (got: '$R')"
fi

echo ""
echo "--- Registration DB ---"
LYTDB=/data/data/it.takeoff.lytcentral/databases/LYT_ServerDataDb
if [ -f "$LYTDB" ]; then
    REG=$($BB strings "$LYTDB" 2>/dev/null | $BB grep -o "mes2[01]" | $BB tail -1)
    echo "  RegStatus marker: $REG (mes21 = registered)"
else
    echo "  [!!] DB not found"
fi

echo ""
echo "--- setCloudStatus (last) ---"
logcat -d 2>/dev/null | $BB grep "setCloudStatus" | $BB tail -n 3

echo ""
echo "=== End ==="