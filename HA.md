# MCLH-01 Recovery Guide

## Что выживает после factory reset

| Расположение | Выживает? | Содержимое |
|---|---|---|
| `/system` | ✅ ДА | `eth0_setup`, `start_ha.sh`, APK, CA-сертификаты |
| `/data` | ❌ НЕТ | Debian chroot, busybox, HA конфиги |
| `/cache` | ❌ НЕТ | Временные файлы |

**Вывод:** после factory reset нужно только восстановить `/data/debian`. Всё остальное уже на месте.

---

## Recovery Kit — что держать на компьютере

```
mclh01-recovery/
├── README.md              ← этот файл
├── bootstrap.sh           ← главный скрипт восстановления
├── setup_chroot.sh        ← настройка Debian (запускается автоматически)
├── busybox-armv7l         ← скачать с busybox.net
├── armhf-rootfs-debian-bullseye.tar  ← из debian-11.7-minimal-armhf-2023-08-22.tar.xz
└── pip-24.0-py3-none-any.whl         ← с PyPI
```

### Подготовка rootfs (один раз)
```bash
# Распаковать внешний архив и сохранить внутренний tar:
tar -xJf debian-11.7-minimal-armhf-2023-08-22.tar.xz
cp debian-11.7-minimal-armhf-2023-08-22/armhf-rootfs-debian-bullseye.tar ./
```

### Скачать busybox
```
https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv7l
```

### Скачать pip wheel
```
https://files.pythonhosted.org/packages/py3/p/pip/pip-24.0-py3-none-any.whl
```

---

## Процедура восстановления (после factory reset)

### Шаг 1 — Подключиться по ADB

```bash
# ADB по WiFi на порту 5555 (eth0_setup восстанавливает это автоматически)
adb connect 192.168.2.223:5555
adb shell
# Убедиться что root:
id   # должно быть uid=0(root)
```

### Шаг 2 — Залить файлы recovery kit

```bash
adb push busybox-armv7l             /data/busybox
adb push armhf-rootfs-debian-bullseye.tar  /data/rootfs.tar
adb push pip-24.0-py3-none-any.whl  /data/pip.whl
adb push bootstrap.sh               /data/bootstrap.sh
adb push setup_chroot.sh            /data/setup_chroot.sh

adb shell /data/busybox chmod 755 /data/busybox
adb shell /data/busybox chmod 755 /data/bootstrap.sh
adb shell /data/busybox chmod 755 /data/setup_chroot.sh
```

### Шаг 3 — Запустить bootstrap

```bash
adb shell sh /data/bootstrap.sh
```

Займёт 10–20 минут (распаковка rootfs + установка пакетов).

### Шаг 4 — Проверить

```bash
# Открыть в браузере:
http://192.168.2.223:8123
```

---

## После каждой перезагрузки

HA запускается **автоматически** через `eth0_setup → start_ha.sh`.
Доступен примерно через 2–3 минуты после загрузки устройства.

### Войти в chroot вручную

```bash
adb shell sh /data/start_debian.sh

# Внутри:
source /opt/ha/bin/activate
hass --config /opt/ha/config    # запустить HA вручную если нужно
```

### Логи HA

```bash
adb shell cat /data/ha.log
```

---

## Структура после восстановления

```
/data/
├── busybox                 ← busybox v1.31.1
├── debian/                 ← Debian 11 armhf chroot
│   └── opt/ha/             ← Home Assistant venv
│       ├── bin/hass
│       └── config/
│           └── configuration.yaml
└── start_debian.sh         ← ручной вход в chroot

/system/bin/
├── eth0_setup              ← вызывает start_ha.sh при загрузке
└── start_ha.sh             ← запуск HA (выживает factory reset)
```

---

## Troubleshooting

### HA не запускается автоматически
```bash
adb shell cat /data/ha.log
adb shell sh /data/start_debian.sh
# Внутри:
source /opt/ha/bin/activate
hass --config /opt/ha/config
```

### Сеть не работает в chroot
```bash
# Убедиться что SELinux permissive:
adb shell cat /sys/fs/selinux/enforce   # должно быть 0
adb shell echo 0 > /sys/fs/selinux/enforce
```

### apt update не работает
```bash
# Внутри chroot:
cat /etc/resolv.conf                    # должны быть nameserver строки
cat /etc/apt/apt.conf.d/99sandbox      # должно быть APT::Sandbox::User "root";
```

### После factory reset ADB не подключается
```bash
# Подождать 1-2 минуты пока eth0_setup отработает
# eth0_setup настраивает ADB TCP и сеть
adb connect 192.168.2.223:5555
```
