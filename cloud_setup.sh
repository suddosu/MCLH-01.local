#!/system/bin/sh
# cloud_setup.sh - installs the cloud-emulation layer ON TOP of a ready
# chroot+HA (bootstrap.sh must have run first).
#
# Run from ADB root shell AFTER Phase A:
#   sh /data/cloud_setup.sh
#
# Idempotent. Does:
#   1. Copy cloud/* into chroot (/opt/cloud)
#   2. Generate certs (inside chroot)
#   3. Install CA into /system/etc/security/cacerts (survives factory reset)
#   4. Write hosts redirect into /system/etc/hosts
#   5. Patch lytcentral registration DB
#   6. Append cloud autostart into start_ha.sh
#   7. Start the emulator now

BB=/data/busybox
DEBIAN=/data/debian
CLOUD_SRC=/data/cloud          # adb push'd httpproxy.py etc. here
CLOUD_DST=$DEBIAN/opt/cloud    # working dir inside chroot

LYTDB=/data/data/it.takeoff.lytcentral/databases/LYT_ServerDataDb
CLOUD_IP=95.163.244.135        # hub2.lifecontrol.ru (dead original)
HTTP_PORT=6666

echo "================================"
echo " ALYT Cloud Emulator Setup"
echo "================================"

# --- Checks ---
[ -x "$BB" ]              || { echo "ERROR: no $BB - run bootstrap.sh first"; exit 1; }
[ -f "$DEBIAN/bin/bash" ] || { echo "ERROR: no chroot at $DEBIAN - run bootstrap.sh first"; exit 1; }
[ -d "$CLOUD_SRC" ]       || { echo "ERROR: no $CLOUD_SRC (adb push cloud /data/cloud)"; exit 1; }
echo "[1/7] Prerequisites: OK"

# --- Environment ---
echo 0 > /sys/fs/selinux/enforce
$BB mount -o remount,rw /system 2>/dev/null
$BB mount -t proc  proc     $DEBIAN/proc    2>/dev/null
$BB mount -t sysfs sysfs    $DEBIAN/sys     2>/dev/null
$BB mount -o bind  /dev     $DEBIAN/dev     2>/dev/null
$BB mount -o bind  /dev/pts $DEBIAN/dev/pts 2>/dev/null

# --- Copy cloud/* into chroot ---
$BB mkdir -p "$CLOUD_DST"
$BB cp "$CLOUD_SRC/httpproxy.py"          "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/tlsproxy.py"           "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/openssl_legacy.cnf"    "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/gen_certs.sh"          "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/patch_registration.py" "$CLOUD_DST/"
$BB chmod 755 "$CLOUD_DST/gen_certs.sh"
echo "[2/7] cloud/* copied into chroot"

# --- Generate certs inside chroot ---
$BB chroot $DEBIAN /usr/bin/python3 -c "
import os
os.setgroups([0,3003,3004])
os.environ['LD_PRELOAD']=''
os.execv('/bin/bash', ['/bin/bash', '/opt/cloud/gen_certs.sh'])
"
CA_HASH=$($BB cat "$CLOUD_DST/ca_hash.txt" 2>/dev/null)
[ -n "$CA_HASH" ] || { echo "ERROR: certs not generated"; exit 1; }
echo "[3/7] Certs ready (CA hash: $CA_HASH)"

# --- CA into system store (survives factory reset) ---
$BB cp "$CLOUD_DST/${CA_HASH}.0" /system/etc/security/cacerts/${CA_HASH}.0
$BB chmod 644 /system/etc/security/cacerts/${CA_HASH}.0
echo "[4/7] CA installed: /system/etc/security/cacerts/${CA_HASH}.0"

# --- hosts redirect (survives factory reset) ---
add_host() {
    if ! $BB grep -q "$1" /system/etc/hosts; then
        echo "127.0.0.1 $1" >> /system/etc/hosts
    fi
}
add_host hub2.lifecontrol.ru
add_host lk2.lifecontrol.ru
add_host lifecontrol.ru
echo "[5/7] hosts redirect written"

# --- Patch registration DB ---
if [ -f "$LYTDB" ]; then
    /system/bin/am force-stop it.takeoff.lytcentral 2>/dev/null
    $BB sleep 1
    $BB cp "$LYTDB" "$CLOUD_DST/LYT_ServerDataDb"
    $BB chroot $DEBIAN /usr/bin/python3 -c "
import os
os.setgroups([0,3003,3004])
os.environ['LD_PRELOAD']=''
os.execv('/usr/bin/python3', ['/usr/bin/python3',
    '/opt/cloud/patch_registration.py', '/opt/cloud/LYT_ServerDataDb'])
"
    $BB cp "$CLOUD_DST/LYT_ServerDataDb" "$LYTDB"
    echo "[6/7] Registration DB patched"
else
    echo "[6/7] WARNING: $LYTDB not found (start lytcentral once, then re-run)"
fi

# --- Cloud autostart: install cloud_autostart.sh into /system + hook ---
START_HA=/system/bin/start_ha.sh
$BB cp "$CLOUD_SRC/cloud_autostart.sh" /system/bin/cloud_autostart.sh
$BB chmod 755 /system/bin/cloud_autostart.sh

if [ -f "$START_HA" ]; then
    if ! $BB grep -q "cloud_autostart" "$START_HA"; then
        echo ""                                            >> "$START_HA"
        echo "# cloud_autostart hook (added by cloud_setup.sh)" >> "$START_HA"
        echo "/system/bin/cloud_autostart.sh &"            >> "$START_HA"
        echo "[7/7] Cloud autostart hooked into start_ha.sh"
    else
        echo "[7/7] Cloud autostart already hooked in start_ha.sh"
    fi
else
    echo "[7/7] WARNING: no $START_HA; hooking eth0_setup instead"
    if ! $BB grep -q "cloud_autostart" /system/bin/eth0_setup; then
        $BB grep -v "^exit 0" /system/bin/eth0_setup > /data/eth0_new.sh
        echo "/system/bin/cloud_autostart.sh &" >> /data/eth0_new.sh
        echo "exit 0" >> /data/eth0_new.sh
        $BB cp /data/eth0_new.sh /system/bin/eth0_setup
        $BB chmod 755 /system/bin/eth0_setup
        $BB rm -f /data/eth0_new.sh
    fi
fi

$BB mount -o remount,ro /system 2>/dev/null

# --- Start emulator NOW ---
echo ""
echo "Starting cloud emulator..."
sh /system/bin/cloud_autostart.sh
$BB sleep 3

# --- Verify ---
echo ""
echo "--- Verify ---"
TEST=$($BB wget -q -T 5 -O- --no-check-certificate --post-data='x=1' \
    "https://127.0.0.1/ServerLYT/LYT_Server/LYT_Login.php" \
    --header="Host: hub2.lifecontrol.ru" 2>/dev/null)
echo "HTTPS LYT_Login -> $TEST"

echo ""
echo "================================"
echo " Cloud Emulator ready!"
echo " Restart lytcentral to apply:"
echo "   am force-stop it.takeoff.lytcentral"
echo "   am start -n it.takeoff.lytcentral/it.takeoff.lytcentral.activities.LytMain"
echo "================================"