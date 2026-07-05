# MCLH-01 (LifeControl 2.0 / ALYT Hub) — Полное восстановление

Воспроизводимое восстановление хаба с нуля после **factory reset**:
Debian chroot + Home Assistant **и** локальный эмулятор облака (хаб
считает себя зарегистрированным и оплаченным, работает без интернета).

Две фазы:
1. **Фаза A — chroot + HA** (`bootstrap.sh` → `setup_chroot.sh`)
2. **Фаза B — эмулятор облака** (`cloud_setup.sh` → `cloud/*`)

---

## 0. Что выживает после factory reset

| Расположение | Выживает | Содержимое |
|---|:---:|---|
| `/system` | ✅ | `eth0_setup`, `start_ha.sh`, `cloud_autostart.sh`, APK, CA-серты, hosts |
| `/data` | ❌ | Debian chroot, busybox, HA, эмулятор облака |

**Вывод:** после reset воспроизводим только `/data`. Автозапуск и
доверенный CA уже в `/system`.

---

## 1. Recovery Kit — что держать на компьютере

```
mclh01-recovery/
├── README.md                 ← этот файл
│
├── bootstrap.sh              ← Фаза A: точка входа
├── setup_chroot.sh           ← Фаза A: настройка Debian+HA (внутри chroot)
├── verify.sh                 ← Фаза A: проверка
│
├── cloud_setup.sh            ← Фаза B: точка входа (после Фазы A)
├── verify_cloud.sh           ← Фаза B: проверка
├── cloud/
│   ├── httpproxy.py          ← HTTP backend (порт 6666)
│   ├── tlsproxy.py           ← TLS 443 → 6666
│   ├── openssl_legacy.cnf    ← TLS 1.0 для старого Android
│   ├── gen_certs.sh          ← генерация CA + server.pem
│   ├── patch_registration.py ← RegStatus=1, AvailableServers
│   └── cloud_autostart.sh    ← автозапуск прокси+iptables (в /system)
│
└── blobs/                    ← большие файлы (НЕ в git; см. §2)
    ├── busybox-armv7l
    ├── armhf-rootfs-debian-bullseye.tar
    └── pip-24.0-py3-none-any.whl
```

Скрипты — в git. Бинарные блобы — в GitHub **Releases** (git-лимит 100 МБ,
rootfs больше). Качать `wget`'ом с устройства или `adb push` с ПК.

---

## 2. Подготовка блобов (один раз)

```bash
# rootfs Debian 11 armhf
tar -xJf debian-11.7-minimal-armhf-2023-08-22.tar.xz
cp debian-11.7-minimal-armhf-2023-08-22/armhf-rootfs-debian-bullseye.tar \
   blobs/
распаковываем из https://rcn-ee.com/rootfs/eewiki/minfs/debian-11.7-minimal-armhf-2023-08-22.tar.xz

# busybox armv7l
wget -O blobs/busybox-armv7l \
  https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv7l

# pip wheel
wget -O blobs/pip-24.0-py3-none-any.whl \
  https://files.pythonhosted.org/packages/py3/p/pip/pip-24.0-py3-none-any.whl
```

---

## 3. Полная процедура восстановления

### Шаг 0 — ADB

`eth0_setup` в `/system` поднимает ADB TCP автоматически (~1–2 мин
после загрузки).

```bash
adb connect 192.168.2.223:5555
adb shell id      # uid=0(root) — обязательно
```

### Шаг 1 — Залить файлы

```bash
# Блобы
adb push blobs/busybox-armv7l              /data/busybox
adb push blobs/armhf-rootfs-debian-bullseye.tar /data/rootfs.tar
adb push blobs/pip-24.0-py3-none-any.whl   /data/pip.whl

# Скрипты Фазы A
adb push bootstrap.sh                      /data/bootstrap.sh
adb push setup_chroot.sh                   /data/setup_chroot.sh
adb push verify.sh                         /data/verify.sh

# Скрипты Фазы B
adb push cloud_setup.sh                    /data/cloud_setup.sh
adb push verify_cloud.sh                   /data/verify_cloud.sh
adb push cloud                             /data/cloud

# Права
adb shell /data/busybox chmod 755 /data/busybox
adb shell /data/busybox chmod 755 /data/*.sh /data/cloud/*.sh /data/cloud/*.py
```

### Шаг 2 — Фаза A: chroot + HA (10–20 мин)

```bash
adb shell sh /data/bootstrap.sh
```

Делает (v3.2, воспроизводимо одной командой):
SELinux permissive → распаковка rootfs (`rootfs.tar` удаляется после,
экономит ~731 МБ) → монтирование ФС → `setup_chroot.sh`:
сеть, apt + `apt-mark hold` python3.9, `deb-extract`, pip через **get-pip**
(rootfs без pip/ensurepip), venv `/opt/ha`, pillow из **piwheels**, HA
2023.1.7, **HA-зависимости с пинами под 2023.1** (aiohttp 3.8.1, yarl 1.8.1,
aiohttp_cors 0.7.0, sqlalchemy 1.4.44, janus, fnvhash,
home-assistant-frontend 20230110.0, `.so` libopenjp2-7), конфиг с
`country: RU`, чистые `start_debian.sh`/`start_ha.sh` → хук в `eth0_setup`.

HA запускается с **`--skip-pip`** (иначе пытается ставить пины и падает).
Скрипт fail-loud: при провале критичного шага останавливается с `FATAL:`.

```bash
adb shell sh /data/verify.sh          # проверка Фазы A
# Открыть: http://192.168.2.223:8123  → onboarding
```

**Первый вход в chroot вручную:** `sh /data/start_debian.sh` (задаёт PATH и
HOME). Ручной перезапуск HA изнутри: `ha-restart`.

### Шаг 3 — Первый запуск lytcentral (создаёт БД)

Эмулятор патчит БД регистрации, которая появляется только после
первого старта приложения. Дай ему стартануть:

```bash
adb shell am start -n it.takeoff.lytcentral/it.takeoff.lytcentral.activities.LytMain
adb shell sleep 5
# Проверь, что БД появилась:
adb shell ls -la /data/data/it.takeoff.lytcentral/databases/LYT_ServerDataDb
```

### Шаг 4 — Фаза B: эмулятор облака

```bash
adb shell sh /data/cloud_setup.sh
```

Делает: копирует `cloud/*` в chroot → генерит CA+server.pem →
ставит CA в `/system/etc/security/cacerts` → hosts-редирект →
патчит БД (`RegStatus=1`, `AvailableServers=hub2.lifecontrol.ru`) →
хук автозапуска в `start_ha.sh` → запускает прокси и iptables.

```bash
adb shell sh /data/verify_cloud.sh    # проверка Фазы B
```

### Шаг 5 — Применить

```bash
adb shell am force-stop it.takeoff.lytcentral
adb shell am start -n it.takeoff.lytcentral/it.takeoff.lytcentral.activities.LytMain
```

**Ожидаемо:** облако не перечёркнуто, «сервис успешно продлён»,
в логах `reachable? true`.

---

## 4. После каждой перезагрузки — автоматика

`eth0_setup` → `start_ha.sh` → (`cloud_autostart.sh` + `hass`).
Всё поднимается само за ~2–3 мин. Ручных действий не нужно.

Проверить после ребута:
```bash
adb shell sh /data/verify_cloud.sh
```

---

## 5. Архитектура эмулятора облака

```
it.takeoff.lytcentral
   │  ходит на hub2.lifecontrol.ru:80/443
   ▼
/system/etc/hosts:  hub2.lifecontrol.ru → 127.0.0.1
   + iptables nat OUTPUT (95.163.244.135 → локальные порты) как страховка
   │
   ├─ :443  tlsproxy.py  (TLS 1.0, наш CA из cacerts)
   │            │ расшифровка
   │            ▼
   └─────────► :6666  httpproxy.py  → JSON-ответы
```

### Эндпоинты (все POST)
| Путь | Ответ |
|---|---|
| `LYT_ts_setup.php` | `{"RESULT":"success","TIMESTAMP":<unix>}` |
| `LYT_Login.php` | `{"RESULT":"success","SERVERLIST_UPDATE":false}` |
| `LYT_Registration_Status.php` | `{"RESULT":"success","USERNAME":"user_5541@..."}` |
| `LYT_Servers_List.php` | `{"RESULT":"success","SERVER_LIST":["hub2.lifecontrol.ru"]}` |
| `LYT_Connection.php` | `{"RESULT":"success","CMD_LIST":[]}` |
| `LYT_Cloud_Commands.php` | `{"RESULT":"success","CMD_LIST":[]}` |
| `LYT_Check_Version_Update.php` | `{"RESULT":"success","UPDATE_AVAILABLE":false}` |
| прочие (`Report`,`Event`,…) | `{"RESULT":"success"}` |

---

## 6. Локальное управление устройствами (без облака)

Хаб держит собственный HTTP API на **порту 8080** — работает
независимо от облака.

```bash
# логин
adb shell '/data/busybox wget -O- \
  --post-data="username=admin&password=admin" \
  http://192.168.2.223:8080/WEB_API_login'
# → {"RESULT":"OK"}, cookie alytsession={"WEBSESSION_ID":"..."}

# статус + устройства (подставь cookie)
COOK='alytsession={"WEBSESSION_ID":"..."}'
adb shell "/data/busybox wget -O- --header=\"Cookie: $COOK\" \
  http://192.168.2.223:8080/WEB_API_get_wifi_data"

# Z-Wave: список устройств
adb shell "/data/busybox wget -O- --header=\"Cookie: $COOK\" \
  --post-data='cmd={\"CMD\":\"CMD00_GET_STATUS\",\"PARAMS\":[]}' \
  http://192.168.2.223:8080/WEB_API_zwave"
```

Z-Wave команды: `CMD01_ADD` (inclusion), `CMD02_REMOVE` (exclusion),
`CMD06_SWITCH_ON_OFF` `[node,"SWITCH_ON"|"SWITCH_OFF"]`,
`CMD11_SET_TEMPERATURE` `[node,val]`, `CMD14_GET_BATTERY_LEVEL` `[node]`.

---

## 7. Troubleshooting

### HTTPS не отвечает / `unsupported protocol`
Старый Android требует TLS 1.0. Проверь, что tlsproxy стартовал с
`OPENSSL_CONF`:
```bash
adb shell cat /data/cloud_tls.log
# должно быть: "tlsproxy: TLS 443 -> 127.0.0.1:6666"
```

### `Address already in use` на 6666/443
Порты в TIME_WAIT. Перезапусти автозапуск (он убивает старые процессы):
```bash
adb shell sh /system/bin/cloud_autostart.sh
```
Если не помогает — поменяй `PORT` в `httpproxy.py` и `BACKEND_PORT` в
`tlsproxy.py` синхронно.

### `regstatus: null`, но `reachable? true`
Некритично — базовая работа (облако «онлайн», оплата) не нарушена.
Полный флоу регистрации завязан на LYT_Registration_Status; проверь БД:
```bash
adb shell sh /data/verify_cloud.sh   # смотри «RegStatus маркер: mes21»
```

### БД не патчится (нет LYT_ServerDataDb)
lytcentral ещё не запускался. Выполни Шаг 3, затем повтори
`cloud_setup.sh`.

### Сеть в chroot не работает
```bash
adb shell cat /sys/fs/selinux/enforce   # должно быть 0
adb shell 'echo 0 > /sys/fs/selinux/enforce'
```

### chroot вручную
```bash
adb shell sh /data/start_debian.sh
# внутри: source /opt/ha/bin/activate; hass --config /opt/ha/config
```

### Логи
```bash
adb shell cat /data/ha.log           # Home Assistant
adb shell cat /data/cloud_http.log   # HTTP backend
adb shell cat /data/cloud_tls.log    # TLS proxy
adb shell '/data/busybox cat /data/debian/opt/cloud/req_log.txt'  # запросы
```

---

## 8. Ключевые грабли (важно при правках)

- **Двойной `https://`**: `AvailableServers.ServerIP` — голый хост
  `hub2.lifecontrol.ru`, БЕЗ схемы. Приложение само добавляет `https://`.
- **`RegStatus` — строка** `"0"/"1"`, не int. `"1"` = REGISTERED.
- **chroot не видит `/data/data`**: БД копируется в `/opt/cloud`,
  правится, копируется обратно (см. `cloud_setup.sh`).
- **Paranoid Networking**: любой сетевой процесс в chroot запускать через
  `os.setgroups([0,3003,3004])` перед `execv`. Иначе сокеты не создаются.
- **SELinux** permissive (`echo 0 > /sys/fs/selinux/enforce`) — нужно
  после каждого ребута (делают start-скрипты).
- **`/system` remount rw** — только на время записи, потом обратно ro.
- **Порты**: TIME_WAIT → менять порт, а не долбить один.
- **busybox** без `curl/find/head/tail/which` — вызывать по полному пути
  `/data/busybox`.

---

## 9. Дальше — VPS-бэкенд (опционально)

Заменить локальный эмулятор на реальный сервис на VPS:
- nginx + Let's Encrypt (настоящий TLS, тогда свой CA не нужен).
- Все эндпоинты §5 как PHP/Python-сервис.
- На хабе в `/system/etc/hosts` заменить `127.0.0.1` на IP VPS →
  прокси в chroot больше не нужны.
- Мобильное приложение (для добавления устройств «как раньше»):
  декомпилировать, сменить URL на VPS, пересобрать, подписать.