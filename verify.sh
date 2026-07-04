#!/system/bin/sh
# Быстрая проверка что всё на месте после bootstrap
# Запускать: adb shell sh /data/verify.sh

BB=/data/busybox

echo "=== MCLH-01 Status Check ==="

check() {
    if [ -e "$2" ]; then
        echo "  [OK] $1"
    else
        echo "  [!!] $1 — НЕ НАЙДЕН: $2"
    fi
}

echo ""
echo "--- /data/ ---"
check "busybox"          /data/busybox
check "debian rootfs"    /data/debian/bin/bash
check "start_debian.sh"  /data/start_debian.sh

echo ""
echo "--- /data/debian/opt/ha/ ---"
check "python3"          /data/debian/opt/ha/bin/python3
check "hass"             /data/debian/opt/ha/bin/hass
check "configuration.yaml" /data/debian/opt/ha/config/configuration.yaml

echo ""
echo "--- /system/bin/ ---"
check "start_ha.sh"      /system/bin/start_ha.sh
check "eth0_setup"       /system/bin/eth0_setup

echo ""
echo "--- SELinux ---"
VAL=$(cat /sys/fs/selinux/enforce 2>/dev/null)
if [ "$VAL" = "0" ]; then
    echo "  [OK] SELinux: permissive"
else
    echo "  [!!] SELinux: enforcing (нужно: echo 0 > /sys/fs/selinux/enforce)"
fi

echo ""
echo "--- eth0_setup вызывает start_ha.sh ---"
if $BB grep -q "start_ha.sh" /system/bin/eth0_setup 2>/dev/null; then
    echo "  [OK] start_ha.sh вызывается при загрузке"
else
    echo "  [!!] start_ha.sh НЕ добавлен в eth0_setup"
fi

echo ""
echo "--- HA лог ---"
if [ -f /data/ha.log ]; then
    $BB tail -n 5 /data/ha.log 2>/dev/null || cat /data/ha.log
else
    echo "  /data/ha.log не найден (HA ещё не запускался)"
fi

echo ""
echo "=== Конец проверки ==="
