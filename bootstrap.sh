#!/system/bin/sh
# MCLH-01 Recovery Bootstrap v1.0
# Запускать из ADB root shell: sh /data/bootstrap.sh
#
# Необходимые файлы в /data/:
#   busybox        — busybox-armv7l
#   rootfs.tar     — armhf-rootfs-debian-bullseye.tar
#   pip.whl        — pip-24.0-py3-none-any.whl
#   setup_chroot.sh

BB=/data/busybox
DEBIAN=/data/debian
ROOTFS=/data/rootfs.tar
PIP_WHL=/data/pip.whl
SETUP=/data/setup_chroot.sh

echo "================================"
echo " MCLH-01 Recovery Bootstrap"
echo "================================"

# --- Проверка prerequisites ---

if [ ! -x "$BB" ]; then
    echo "ОШИБКА: busybox не найден в $BB"
    echo "Выполни:"
    echo "  adb push busybox-armv7l /data/busybox"
    echo "  adb shell /data/busybox chmod 755 /data/busybox"
    exit 1
fi
echo "[1/9] busybox: OK"

if [ ! -f "$ROOTFS" ]; then
    echo "ОШИБКА: rootfs не найден в $ROOTFS"
    echo "Выполни:"
    echo "  adb push armhf-rootfs-debian-bullseye.tar /data/rootfs.tar"
    exit 1
fi
echo "[2/9] rootfs.tar: OK"

if [ ! -f "$SETUP" ]; then
    echo "ОШИБКА: setup_chroot.sh не найден в $SETUP"
    echo "Выполни:"
    echo "  adb push setup_chroot.sh /data/setup_chroot.sh"
    exit 1
fi
echo "[3/9] setup_chroot.sh: OK"

# --- SELinux permissive ---
echo 0 > /sys/fs/selinux/enforce
echo "[4/9] SELinux: permissive"

# --- Распаковка rootfs ---
if [ ! -f "$DEBIAN/bin/bash" ]; then
    echo "[5/9] Распаковываем rootfs (3-5 минут)..."
    $BB mkdir -p $DEBIAN
    $BB tar -xf $ROOTFS -C $DEBIAN
    echo "[5/9] rootfs распакован"
else
    echo "[5/9] rootfs: уже на месте"
fi

# --- Монтирование ФС ---
$BB mount -t proc  proc      $DEBIAN/proc    2>/dev/null
$BB mount -t sysfs sysfs     $DEBIAN/sys     2>/dev/null
$BB mount -o bind  /dev      $DEBIAN/dev     2>/dev/null
$BB mount -o bind  /dev/pts  $DEBIAN/dev/pts 2>/dev/null
echo "[6/9] Файловые системы смонтированы"

# --- Копируем скрипты в chroot ---
$BB cp $SETUP $DEBIAN/tmp/setup_chroot.sh
$BB chmod 755 $DEBIAN/tmp/setup_chroot.sh

if [ -f "$PIP_WHL" ]; then
    $BB cp $PIP_WHL $DEBIAN/tmp/pip.whl
    echo "[7/9] pip.whl скопирован"
else
    echo "[7/9] pip.whl не найден — будет скачан автоматически"
fi

# --- Запуск настройки внутри chroot ---
echo "[8/9] Запускаем setup_chroot.sh..."
$BB chroot $DEBIAN /usr/bin/python3 -c "
import os
os.setgroups([0, 3003, 3004])
os.environ['LD_PRELOAD'] = ''
os.execv('/bin/bash', ['/bin/bash', '/tmp/setup_chroot.sh'])
"

# Проверяем что setup завершился успешно
if [ ! -f "$DEBIAN/opt/ha/bin/hass" ]; then
    echo "ОШИБКА: setup_chroot.sh завершился с ошибкой"
    echo "Запусти вручную для диагностики:"
    echo "  $BB chroot $DEBIAN /bin/bash"
    exit 1
fi

# --- Настройка автозапуска в /system ---
echo "[9/9] Настраиваем автозапуск..."

$BB mount -o remount,rw /system 2>/dev/null

# Создаём /data/start_debian.sh (ручной вход в chroot)
$BB printf '%s\n' \
    '#!/system/bin/sh' \
    'echo 0 > /sys/fs/selinux/enforce' \
    'mount -t proc proc /data/debian/proc 2>/dev/null' \
    'mount -t sysfs sysfs /data/debian/sys 2>/dev/null' \
    'mount -o bind /dev /data/debian/dev 2>/dev/null' \
    'mount -o bind /dev/pts /data/debian/dev/pts 2>/dev/null' \
    '/data/busybox chroot /data/debian /usr/bin/python3 -c "import os; os.setgroups([0,3003,3004]); os.environ[chr(76)+chr(68)+chr(95)+chr(80)+chr(82)+chr(69)+chr(76)+chr(79)+chr(65)+chr(68)]=str(); os.execv(chr(47)+chr(98)+chr(105)+chr(110)+chr(47)+chr(98)+chr(97)+chr(115)+chr(104),[chr(47)+chr(98)+chr(105)+chr(110)+chr(47)+chr(98)+chr(97)+chr(115)+chr(104)])"' \
    > /data/start_debian.sh
$BB chmod 755 /data/start_debian.sh

# Копируем start_ha.sh (написан setup_chroot.sh)
if [ -f "$DEBIAN/tmp/start_ha.sh" ]; then
    $BB cp $DEBIAN/tmp/start_ha.sh /system/bin/start_ha.sh
    $BB chmod 755 /system/bin/start_ha.sh
    echo "    /system/bin/start_ha.sh: установлен"
else
    echo "    ПРЕДУПРЕЖДЕНИЕ: start_ha.sh не найден в chroot/tmp"
fi

# Добавляем вызов в eth0_setup (если ещё не добавлен)
if ! $BB grep -q "start_ha.sh" /system/bin/eth0_setup; then
    # Перестраиваем файл: всё кроме "exit 0" + наша строка + exit 0
    $BB grep -v "^exit 0" /system/bin/eth0_setup > /tmp/eth0_new.sh
    echo "" >> /tmp/eth0_new.sh
    echo "# Start Home Assistant" >> /tmp/eth0_new.sh
    echo "/system/bin/start_ha.sh &" >> /tmp/eth0_new.sh
    echo "exit 0" >> /tmp/eth0_new.sh
    $BB cp /tmp/eth0_new.sh /system/bin/eth0_setup
    $BB chmod 755 /system/bin/eth0_setup
    echo "    eth0_setup: добавлен вызов start_ha.sh"
else
    echo "    eth0_setup: start_ha.sh уже добавлен"
fi

$BB mount -o remount,ro /system 2>/dev/null

echo ""
echo "================================"
echo " Bootstrap завершён!"
echo ""
echo " Войти в chroot: sh /data/start_debian.sh"
echo " HA доступен: http://192.168.2.223:8123"
echo " После перезагрузки HA стартует автоматически"
echo "================================"
