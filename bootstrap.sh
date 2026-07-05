#!/system/bin/sh
# MCLH-01 Recovery Bootstrap v3.2
# Run from ADB root shell: sh /data/bootstrap.sh
#
# Required in /data/:  busybox, rootfs.tar (inner armhf tar), setup_chroot.sh
# rootfs.tar is auto-removed after unpack to free space.
# All ASCII. start_ha.sh AND start_debian.sh are written by setup_chroot.sh
# (clean, no chr() encoding) and copied out here.

BB=/data/busybox
DEBIAN=/data/debian
ROOTFS=/data/rootfs.tar
SETUP=/data/setup_chroot.sh

echo "================================"
echo " MCLH-01 Recovery Bootstrap v3.2"
echo "================================"

[ -x "$BB" ]      || { echo "ERROR: busybox not executable (adb shell chmod 755 /data/busybox)"; exit 1; }
echo "[1/9] busybox: OK"
[ -f "$ROOTFS" ]  || { echo "ERROR: rootfs not found at $ROOTFS"; exit 1; }
echo "[2/9] rootfs.tar: OK"
[ -f "$SETUP" ]   || { echo "ERROR: setup_chroot.sh not found at $SETUP"; exit 1; }
echo "[3/9] setup_chroot.sh: OK"

echo 0 > /sys/fs/selinux/enforce
echo "[4/9] SELinux: permissive"

if [ ! -f "$DEBIAN/bin/bash" ]; then
    echo "[5/9] Unpacking rootfs (3-5 min)..."
    $BB mkdir -p $DEBIAN
    $BB tar -xf $ROOTFS -C $DEBIAN
    if [ -f "$DEBIAN/bin/bash" ]; then
        $BB rm -f "$ROOTFS"
        echo "[5/9] rootfs unpacked (rootfs.tar removed to free space)"
    else
        echo "ERROR: rootfs unpack failed (bin/bash missing)"; exit 1
    fi
else
    echo "[5/9] rootfs: already present"
fi

$BB mount -t proc  proc      $DEBIAN/proc    2>/dev/null
$BB mount -t sysfs sysfs     $DEBIAN/sys     2>/dev/null
$BB mount -o bind  /dev      $DEBIAN/dev     2>/dev/null
$BB mount -o bind  /dev/pts  $DEBIAN/dev/pts 2>/dev/null
echo "[6/9] Filesystems mounted"

$BB cp $SETUP $DEBIAN/tmp/setup_chroot.sh
$BB chmod 755 $DEBIAN/tmp/setup_chroot.sh
echo "[7/9] setup_chroot.sh copied into chroot"

echo "[8/9] Running setup_chroot.sh inside chroot..."
$BB chroot $DEBIAN /usr/bin/python3 -c "
import os
os.setgroups([0, 3003, 3004])
os.environ['LD_PRELOAD'] = ''
os.execv('/bin/bash', ['/bin/bash', '/tmp/setup_chroot.sh'])
"

[ -f "$DEBIAN/opt/ha/bin/hass" ] || { echo "ERROR: setup did not finish (no hass). Debug: sh /data/start_debian.sh"; exit 1; }

echo "[9/9] Wiring autostart..."
$BB mount -o remount,rw /system 2>/dev/null

# start_debian.sh (manual chroot entry) - written by setup_chroot, copied here
if [ -f "$DEBIAN/tmp/start_debian.sh" ]; then
    $BB cp $DEBIAN/tmp/start_debian.sh /data/start_debian.sh
    $BB chmod 755 /data/start_debian.sh
    echo "    /data/start_debian.sh: installed"
else
    echo "    WARNING: start_debian.sh not found in chroot/tmp"
fi

# start_ha.sh -> /system/bin (survives factory reset)
if [ -f "$DEBIAN/tmp/start_ha.sh" ]; then
    $BB cp $DEBIAN/tmp/start_ha.sh /system/bin/start_ha.sh
    $BB chmod 755 /system/bin/start_ha.sh
    echo "    /system/bin/start_ha.sh: installed"
else
    echo "    WARNING: start_ha.sh not found in chroot/tmp"
fi

# Hook start_ha.sh into eth0_setup. Use /data (Android shell has NO /tmp).
# Verify the cp actually succeeded before claiming success.
if ! $BB grep -q "start_ha.sh" /system/bin/eth0_setup; then
    $BB grep -v "^exit 0" /system/bin/eth0_setup > /data/eth0_new.sh
    echo ""                        >> /data/eth0_new.sh
    echo "# Start Home Assistant"  >> /data/eth0_new.sh
    echo "/system/bin/start_ha.sh &" >> /data/eth0_new.sh
    echo "exit 0"                  >> /data/eth0_new.sh
    if $BB cp /data/eth0_new.sh /system/bin/eth0_setup; then
        $BB chmod 755 /system/bin/eth0_setup
        $BB rm -f /data/eth0_new.sh
        echo "    eth0_setup: start_ha.sh hook added"
    else
        echo "    ERROR: failed to write eth0_setup hook"
    fi
else
    echo "    eth0_setup: start_ha.sh hook already present"
fi

$BB mount -o remount,ro /system 2>/dev/null

echo ""
echo "================================"
echo " Bootstrap complete (v3.2)"
echo " Enter chroot:  sh /data/start_debian.sh"
echo " HA:            http://192.168.2.223:8123"
echo " Autostart: eth0_setup -> start_ha.sh (after reboot, ~2-3 min)"
echo "================================"