#!/system/bin/sh
# cloud_setup.sh — устанавливает слой эмуляции облака ПОВЕРХ готового
# chroot+HA (bootstrap-HA.sh уже должен быть отработан).
#
# Запускать из ADB root shell ПОСЛЕ bootstrap-HA.sh:
#   sh /data/cloud_setup.sh
#
# Идемпотентно. Делает:
#   1. Копирует cloud/* в chroot (/opt/cloud)
#   2. Генерит сертификаты (внутри chroot)
#   3. Ставит CA в /system/etc/security/cacerts (переживает reset)
#   4. Прописывает hosts-редирект в /system/etc/hosts
#   5. Патчит БД регистрации lytcentral
#   6. Дописывает автозапуск облака в start_ha.sh
#   7. Запускает эмулятор здесь и сейчас

BB=/data/busybox
DEBIAN=/data/debian
CLOUD_SRC=/data/cloud          # сюда adb push'нуты httpproxy.py и пр.
CLOUD_DST=$DEBIAN/opt/cloud    # рабочая папка внутри chroot

LYTDB=/data/data/it.takeoff.lytcentral/databases/LYT_ServerDataDb
CLOUD_IP=95.163.244.135        # hub2.lifecontrol.ru (мёртвый оригинал)
HTTP_PORT=6666

echo "================================"
echo " ALYT Cloud Emulator Setup"
echo "================================"

# --- Проверки ---
if [ ! -x "$BB" ]; then
    echo "ОШИБКА: нет $BB — сначала выполни bootstrap-HA.sh"
    exit 1
fi
if [ ! -f "$DEBIAN/bin/bash" ]; then
    echo "ОШИБКА: нет chroot в $DEBIAN — сначала bootstrap-HA.sh"
    exit 1
fi
if [ ! -d "$CLOUD_SRC" ]; then
    echo "ОШИБКА: нет $CLOUD_SRC"
    echo "Выполни: adb push cloud /data/cloud"
    exit 1
fi
echo "[1/7] Предусловия: OK"

# --- Окружение ---
echo 0 > /sys/fs/selinux/enforce
$BB mount -o remount,rw /system 2>/dev/null

# Убедимся, что chroot смонтирован (после свежего ребута может быть не смонтирован)
$BB mount -t proc  proc     $DEBIAN/proc    2>/dev/null
$BB mount -t sysfs sysfs    $DEBIAN/sys     2>/dev/null
$BB mount -o bind  /dev     $DEBIAN/dev     2>/dev/null
$BB mount -o bind  /dev/pts $DEBIAN/dev/pts 2>/dev/null

# --- Копируем cloud/* в chroot ---
$BB mkdir -p "$CLOUD_DST"
$BB cp "$CLOUD_SRC/httpproxy.py"          "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/tlsproxy.py"           "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/openssl_legacy.cnf"    "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/gen_certs.sh"          "$CLOUD_DST/"
$BB cp "$CLOUD_SRC/patch_registration.py" "$CLOUD_DST/"
$BB chmod 755 "$CLOUD_DST/gen_certs.sh"
echo "[2/7] cloud/* скопированы в chroot"

# --- Генерим сертификаты внутри chroot ---
$BB chroot $DEBIAN /usr/bin/python3 -c "
import os
os.setgroups([0,3003,3004])
os.environ['LD_PRELOAD']=''
os.execv('/bin/bash', ['/bin/bash', '/opt/cloud/gen_certs.sh'])
"
CA_HASH=$($BB cat "$CLOUD_DST/ca_hash.txt" 2>/dev/null)
if [ -z "$CA_HASH" ]; then
    echo "ОШИБКА: сертификаты не сгенерировались"
    exit 1
fi
echo "[3/7] Сертификаты готовы (CA hash: $CA_HASH)"

# --- CA в системное хранилище (переживает factory reset) ---
$BB cp "$CLOUD_DST/${CA_HASH}.0" /system/etc/security/cacerts/${CA_HASH}.0
$BB chmod 644 /system/etc/security/cacerts/${CA_HASH}.0
echo "[4/7] CA установлен в /system/etc/security/cacerts/${CA_HASH}.0"

# --- hosts-редирект (переживает factory reset) ---
add_host() {
    if ! $BB grep -q "$1" /system/etc/hosts; then
        echo "127.0.0.1 $1" >> /system/etc/hosts
    fi
}
add_host hub2.lifecontrol.ru
add_host lk2.lifecontrol.ru
add_host lifecontrol.ru
echo "[5/7] hosts-редирект прописан"

# --- Патч БД регистрации ---
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
    echo "[6/7] БД регистрации пропатчена"
else
    echo "[6/7] ПРЕДУПРЕЖДЕНИЕ: $LYTDB не найден"
    echo "      (хаб ещё не создал БД — запусти lytcentral один раз,"
    echo "       потом повтори cloud_setup.sh)"
fi

# --- Автозапуск облака: ставим cloud_autostart.sh в /system и хук ---
# start_ha.sh уже стоит в /system/bin (от bootstrap.sh) и вызывается из
# eth0_setup. Дописываем в его КОНЕЦ вызов cloud_autostart.sh (в фоне),
# чтобы эмулятор поднимался при загрузке вместе с HA.
START_HA=/system/bin/start_ha.sh
TMP=/data/local/tmp

$BB cp "$CLOUD_SRC/cloud_autostart.sh" /system/bin/cloud_autostart.sh
$BB chmod 755 /system/bin/cloud_autostart.sh

if [ -f "$START_HA" ]; then
    if ! $BB grep -q "cloud_autostart" "$START_HA"; then
        # Просто дописываем вызов в конец файла (start_ha.sh не имеет
        # 'exit', заканчивается запуском hass в фоне — добавление в конец
        # безопасно; наш вызов тоже в фоне)
        echo "" >> "$START_HA"
        echo "# cloud_autostart hook (added by cloud_setup.sh)" >> "$START_HA"
        echo "/system/bin/cloud_autostart.sh &" >> "$START_HA"
        echo "[7/7] Автозапуск облака добавлен в start_ha.sh"
    else
        echo "[7/7] Автозапуск облака уже прописан в start_ha.sh"
    fi
else
    # start_ha.sh нет (Фаза A не завершена?) — вешаем на eth0_setup напрямую
    echo "[7/7] ВНИМАНИЕ: $START_HA нет; вешаю на eth0_setup"
    if ! $BB grep -q "cloud_autostart" /system/bin/eth0_setup; then
        $BB grep -v "^exit 0" /system/bin/eth0_setup > $TMP/eth0_new.sh
        echo "/system/bin/cloud_autostart.sh &" >> $TMP/eth0_new.sh
        echo "exit 0" >> $TMP/eth0_new.sh
        $BB cp $TMP/eth0_new.sh /system/bin/eth0_setup
        $BB chmod 755 /system/bin/eth0_setup
    fi
fi

$BB mount -o remount,ro /system 2>/dev/null

# --- Запускаем эмулятор ПРЯМО СЕЙЧАС ---
echo ""
echo "Запускаем эмулятор облака..."
sh /system/bin/cloud_autostart.sh
$BB sleep 3

# --- Проверка ---
echo ""
echo "--- Проверка ---"
TEST=$($BB wget -q -T 5 -O- --no-check-certificate --post-data='x=1' \
    "https://127.0.0.1/ServerLYT/LYT_Server/LYT_Login.php" \
    --header="Host: hub2.lifecontrol.ru" 2>/dev/null)
echo "HTTPS LYT_Login → $TEST"

echo ""
echo "================================"
echo " Cloud Emulator готов!"
echo " Перезапусти lytcentral для применения:"
echo "   am force-stop it.takeoff.lytcentral"
echo "   am start -n it.takeoff.lytcentral/it.takeoff.lytcentral.activities.LytMain"
echo "================================"
