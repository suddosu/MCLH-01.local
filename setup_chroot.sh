#!/bin/bash
# Запускается внутри Debian chroot через bootstrap.sh
# НЕ запускать напрямую

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_PRELOAD=""

echo "--- setup_chroot.sh start ---"

# ================================================================
# 1. Сеть
# ================================================================
echo "[1/8] Настройка сети..."

echo "nameserver 8.8.8.8"  > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# nsswitch: убираем mdns который требует avahi
sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf

echo "[1/8] OK"

# ================================================================
# 2. APT
# ================================================================
echo "[2/8] Настройка apt..."

# Отключаем sandbox (apt форкает процессы без inet группы)
mkdir -p /etc/apt/apt.conf.d
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox

# Обёртки для apt методов — восстанавливают inet группу (3003) в subprocess
for method in http https; do
    if [ -f /usr/lib/apt/methods/$method ] && [ ! -f /usr/lib/apt/methods/${method}.real ]; then
        mv /usr/lib/apt/methods/$method /usr/lib/apt/methods/${method}.real
    fi
    if [ -f /usr/lib/apt/methods/${method}.real ]; then
        python3 -c "
import os
content = '''#!/usr/bin/python3
import os
os.setgroups([0, 3003, 3004])
os.execv('/usr/lib/apt/methods/${method}.real', ['/usr/lib/apt/methods/${method}.real'])
'''
open('/usr/lib/apt/methods/${method}', 'w').write(content)
os.chmod('/usr/lib/apt/methods/${method}', 0o755)
"
    fi
done

# Убираем сломанный rcn-ee репозиторий
sed -i '/rcn-ee/d' /etc/apt/sources.list 2>/dev/null || true

apt-get update -q 2>&1 | tail -5
echo "[2/8] OK"

# ================================================================
# 3. pip
# ================================================================
echo "[3/8] Установка pip..."

if ! python3 -c "import pip" 2>/dev/null; then
    PIP_WHL=""

    # Проверяем наличие pip.whl от bootstrap
    if [ -f /tmp/pip.whl ]; then
        PIP_SIZE=$(python3 -c "import os; print(os.path.getsize('/tmp/pip.whl'))")
        if [ "$PIP_SIZE" -gt 1000000 ]; then
            PIP_WHL=/tmp/pip.whl
            echo "    pip.whl найден локально"
        fi
    fi

    # Скачиваем если не нашли
    if [ -z "$PIP_WHL" ]; then
        echo "    Скачиваем pip.whl..."
        curl -L -o /tmp/pip.whl \
            "https://files.pythonhosted.org/packages/py3/p/pip/pip-24.0-py3-none-any.whl"
        PIP_WHL=/tmp/pip.whl
    fi

    # Устанавливаем в site-packages
    python3 -c "
import zipfile
z = zipfile.ZipFile('/tmp/pip.whl')
z.extractall('/usr/lib/python3/dist-packages/')
print('pip распакован')
"
    # Создаём исполняемый скрипт
    python3 -c "
script = '''#!/usr/bin/python3
import sys
sys.path.insert(0, \"/usr/lib/python3/dist-packages\")
from pip._internal.cli.main import main
sys.exit(main())
'''
open('/usr/local/bin/pip3', 'w').write(script)
open('/usr/local/bin/pip', 'w').write(script)
import os
os.chmod('/usr/local/bin/pip3', 0o755)
os.chmod('/usr/local/bin/pip', 0o755)
"
fi

python3 -m pip --version
echo "[3/8] OK"

# ================================================================
# 4. distutils (нужен для pip builds)
# ================================================================
echo "[4/8] Установка distutils..."

if [ ! -f /usr/lib/python3.9/distutils/__init__.py ]; then
    cd /tmp

    # Пробуем через apt
    apt-get download python3-distutils -q 2>/dev/null
    DEB=$(ls /tmp/python3-distutils*.deb 2>/dev/null | head -1)

    # Fallback: скачиваем напрямую
    if [ -z "$DEB" ]; then
        curl -L -o /tmp/distutils.deb \
            "http://ftp.debian.org/debian/pool/main/p/python3-stdlib-extensions/python3-distutils_3.9.2-1_all.deb"
        DEB=/tmp/distutils.deb
    fi

    dpkg-deb -x "$DEB" /tmp/distutils_pkg
    cp -r /tmp/distutils_pkg/usr/lib/python3.9/distutils /usr/lib/python3.9/
    rm -rf /tmp/distutils_pkg "$DEB"
fi

python3 -c "import distutils; print('distutils:', distutils.__file__)"
echo "[4/8] OK"

# ================================================================
# 5. setuptools (даёт pkg_resources)
# ================================================================
echo "[5/8] setuptools==67.8.0..."

# Пиним версию которая содержит pkg_resources
pip install "setuptools==67.8.0" --quiet

python3 -c "import pkg_resources; print('pkg_resources: OK')"
echo "[5/8] OK"

# ================================================================
# 6. Виртуальное окружение для HA
# ================================================================
echo "[6/8] Создаём venv /opt/ha..."

if [ ! -f /opt/ha/bin/python3 ]; then
    python3 -m venv /opt/ha --without-pip

    # Копируем pip в venv
    cp -r /usr/lib/python3/dist-packages/pip /opt/ha/lib/python3.9/site-packages/

    # Копируем distutils в venv
    cp -r /usr/lib/python3.9/distutils /opt/ha/lib/python3.9/

    # Создаём pip скрипт в venv
    python3 -c "
script = '''#!/opt/ha/bin/python3
import sys
sys.path.insert(0, \"/opt/ha/lib/python3.9/site-packages\")
from pip._internal.cli.main import main
sys.exit(main())
'''
open('/opt/ha/bin/pip', 'w').write(script)
open('/opt/ha/bin/pip3', 'w').write(script)
import os
os.chmod('/opt/ha/bin/pip', 0o755)
os.chmod('/opt/ha/bin/pip3', 0o755)
"
fi

source /opt/ha/bin/activate

# Копируем pkg_resources в venv если отсутствует
python3 -c "import pkg_resources" 2>/dev/null || \
    cp -r /usr/lib/python3.9/site-packages/pkg_resources \
          /opt/ha/lib/python3.9/site-packages/ 2>/dev/null || true

/opt/ha/bin/pip install wheel "setuptools==67.8.0" --quiet
echo "[6/8] venv OK"

# ================================================================
# 7. Home Assistant
# ================================================================
echo "[7/8] Установка Home Assistant (10-15 минут)..."

# psutil: берём готовый armhf wheel без компиляции
/opt/ha/bin/pip install \
    --index-url https://www.piwheels.org/simple \
    psutil --quiet

# Home Assistant
/opt/ha/bin/pip install "homeassistant==2023.1.7" --quiet

# numpy тянется как зависимость но ломается (нет libcblas) — убираем
/opt/ha/bin/pip uninstall -y numpy 2>/dev/null || true

# Фиксируем setuptools чтобы не сбивалось
/opt/ha/bin/pip install "setuptools==67.8.0" --quiet --force-reinstall

# Копируем pkg_resources после переустановки setuptools
cp -r /opt/ha/lib/python3.9/site-packages/pkg_resources \
      /opt/ha/lib/python3.9/site-packages/_pkg_resources_backup 2>/dev/null || true

python3 -c "import pkg_resources; print('pkg_resources в venv: OK')"

echo "[7/8] Home Assistant установлен"

# ================================================================
# 8. Конфиги
# ================================================================
echo "[8/8] Создаём конфиги..."

# HA configuration.yaml
mkdir -p /opt/ha/config
if [ ! -f /opt/ha/config/configuration.yaml ]; then
    python3 -c "
config = '''# Home Assistant — MCLH-01
homeassistant:
  name: Home
  latitude: 55.75
  longitude: 37.62
  unit_system: metric
  time_zone: Europe/Moscow

# Веб-интерфейс
frontend:

# REST API
http:

api:

# Пустые разделы чтобы не было ошибок
automation: []
script: []
scene: []

# Отключаем сломанные компоненты
logger:
  default: warning
  logs:
    homeassistant.components.cloud: critical
    homeassistant.components.mobile_app: critical
    homeassistant.components.hardware: critical
'''
open('/opt/ha/config/configuration.yaml', 'w').write(config)
print('configuration.yaml создан')
"
fi

# APT sandbox конфиг (на всякий случай повторно)
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox

# HA автостарт скрипт для /system/bin/ (будет скопирован bootstrap.sh)
python3 -c "
script = '''#!/system/bin/sh
# Автостарт Home Assistant
# Копируется в /system/bin/start_ha.sh через bootstrap.sh
sleep 15
echo 0 > /sys/fs/selinux/enforce
mount -t proc proc /data/debian/proc 2>/dev/null
mount -t sysfs sysfs /data/debian/sys 2>/dev/null
mount -o bind /dev /data/debian/dev 2>/dev/null
mount -o bind /dev/pts /data/debian/dev/pts 2>/dev/null
/data/busybox chroot /data/debian /opt/ha/bin/python3 -c \"import os; os.setgroups([0,3003,3004]); os.environ[chr(76)+chr(68)+chr(95)+chr(80)+chr(82)+chr(69)+chr(76)+chr(79)+chr(65)+chr(68)]=str(); os.execv(str(chr(47)+chr(111)+chr(112)+chr(116)+chr(47)+chr(104)+chr(97)+chr(47)+chr(98)+chr(105)+chr(110)+chr(47)+chr(104)+chr(97)+chr(115)+chr(115)),[str(chr(104)+chr(97)+chr(115)+chr(115)),str(chr(45)+chr(99)),str(chr(47)+chr(111)+chr(112)+chr(116)+chr(47)+chr(104)+chr(97)+chr(47)+chr(99)+chr(111)+chr(110)+chr(102)+chr(105)+chr(103))])\" >> /data/ha.log 2>&1
'''
open('/tmp/start_ha.sh', 'w').write(script)
import os
os.chmod('/tmp/start_ha.sh', 0o755)
print('start_ha.sh подготовлен')
"

echo "[8/8] Конфиги созданы"

echo ""
echo "--- setup_chroot.sh завершён ---"
echo "Проверка: /opt/ha/bin/hass --version"
/opt/ha/bin/hass --version 2>/dev/null || echo "(--version не поддерживается в этой версии)"
