#!/system/bin/sh
# cloud_autostart.sh — поднимает эмулятор облака.
# Вызывается из start_ha.sh при загрузке И вручную из cloud_setup.sh.
# Идемпотентно: чистит старые процессы перед запуском.
#
# Ставится в /system/bin/ (переживает factory reset).

BB=/data/busybox
DEBIAN=/data/debian
CLOUD=$DEBIAN/opt/cloud
CLOUD_IP=95.163.244.135
HTTP_PORT=6666

# Ждём, пока /data и chroot будут доступны (после ребута)
i=0
while [ ! -f "$CLOUD/httpproxy.py" ] && [ $i -lt 30 ]; do
    $BB sleep 2
    i=$((i + 1))
done
[ -f "$CLOUD/httpproxy.py" ] || exit 0

echo 0 > /sys/fs/selinux/enforce

# Убеждаемся, что chroot смонтирован
$BB mount -t proc  proc     $DEBIAN/proc    2>/dev/null
$BB mount -t sysfs sysfs    $DEBIAN/sys     2>/dev/null
$BB mount -o bind  /dev     $DEBIAN/dev     2>/dev/null
$BB mount -o bind  /dev/pts $DEBIAN/dev/pts 2>/dev/null

# --- Чистим старые процессы прокси (по имени скрипта) ---
# killall внутри chroot; если процессы висят — освобождаем порты
$BB chroot $DEBIAN /usr/bin/python3 -c "
import os, signal, glob
os.environ['LD_PRELOAD']=''
for pid in glob.glob('/proc/[0-9]*'):
    try:
        cl = open(pid+'/cmdline','rb').read().decode('utf-8','replace')
        if 'httpproxy.py' in cl or 'tlsproxy.py' in cl:
            os.kill(int(pid.split('/')[-1]), signal.SIGKILL)
    except Exception:
        pass
" 2>/dev/null
$BB sleep 2

# --- HTTP backend (порт 6666) ---
$BB chroot $DEBIAN /usr/bin/python3 -c "
import os
os.setgroups([0,3003,3004])
os.environ['LD_PRELOAD']=''
os.execv('/usr/bin/python3', ['/usr/bin/python3', '/opt/cloud/httpproxy.py'])
" > /data/cloud_http.log 2>&1 &

$BB sleep 1

# --- TLS proxy (порт 443 → 6666) ---
$BB chroot $DEBIAN /usr/bin/python3 -c "
import os
os.setgroups([0,3003,3004])
os.environ['LD_PRELOAD']=''
os.environ['OPENSSL_CONF']='/opt/cloud/openssl_legacy.cnf'
os.execv('/usr/bin/python3', ['/usr/bin/python3', '/opt/cloud/tlsproxy.py'])
" > /data/cloud_tls.log 2>&1 &

$BB sleep 1

# --- iptables редиректы ---
# HTTP на мёртвый облачный IP → наш backend (на случай, если hosts не сработал)
/system/bin/iptables -t nat -C OUTPUT -d $CLOUD_IP -p tcp --dport 80 \
    -j REDIRECT --to-ports $HTTP_PORT 2>/dev/null || \
/system/bin/iptables -t nat -A OUTPUT -d $CLOUD_IP -p tcp --dport 80 \
    -j REDIRECT --to-ports $HTTP_PORT

# HTTPS на мёртвый облачный IP → наш TLS (443 слушаем локально)
/system/bin/iptables -t nat -C OUTPUT -d $CLOUD_IP -p tcp --dport 443 \
    -j REDIRECT --to-ports 443 2>/dev/null || \
/system/bin/iptables -t nat -A OUTPUT -d $CLOUD_IP -p tcp --dport 443 \
    -j REDIRECT --to-ports 443

echo "cloud_autostart: proxies up, iptables set"
