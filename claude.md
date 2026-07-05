# LifeControl / ALYT Hub — Cloud-Independent Restore

Проект: превратить EOL IoT-хаб **LifeControl 2.0** в полностью локальную,
облако-независимую систему умного дома с Home Assistant. Всё окружение
разворачивается **из GitHub-репозитория одной командой** и переживает
factory reset / ребут.

---

## 1. Железо и доступ

| Параметр | Значение |
|----------|----------|
| Устройство | LifeControl 2.0 (Megafon Hub), Android 4.x, MediaTek ARMv7 |
| IP | `192.168.2.223` |
| MAC WiFi | `<WIFI_MAC>` |
| MAC LAN | `<LAN_MAC>` |
| ADB | TCP `:5555`, root-shell |
| FW | `2.1.7 ROM v0.78` |

### Радиомодули (подтверждено из APK)
| Модуль | Чип | Kernel node |
|--------|-----|-------------|
| Z-Wave | Sigma Designs ZM5304 (EU/RU) | `/dev/lyt_cc_irq`, `/dev/lyt_cc_icp_data` |
| ZigBee | TI CC2538 (HA 1.2.1, SPI) | `/dev/lyt_zb_prog_data` |
| RF 868 | TI CC1110 | `/dev/ttyMT0` |
| IR | custom | `/dev/ircontrol` |

Прошивки чипов: внутри `/system/app/AlytHub.apk` → `assets/firmware/`.

---

## 2. Что переживает factory reset — КРИТИЧНО

`/data` **полностью стирается** при factory reset. `/system` — нет.

| Артефакт | Где | Reset | Ребут |
|----------|-----|:-----:|:-----:|
| chroot Debian + HA | `/data/debian` | ❌ | ✅ |
| busybox | `/data/busybox` | ❌ | ✅ |
| Прокси-скрипты, сертификаты | `/data/...` | ❌ | ✅ |
| Патч регистрации в БД | `/data/data/...` | ❌ | ⚠️ перезапишется |
| `eth0_setup` (автозапуск) | `/system/bin/` | ✅ | ✅ |
| hosts-редирект | `/system/etc/hosts` | ✅ | ✅ |
| CA-сертификат (`7a0d056c.0`) | `/system/etc/security/cacerts/` | ✅ | ✅ |

**Стратегия**: НЕ полагаться на `/data`. Всё, что там, — воспроизводимо
из репозитория через `bootstrap.sh`. `/system` трогаем минимально
(только автозапуск-хук, hosts, CA).

---

## 3. Раскладка GitHub-репозитория

```
alyt-restore/
├── bootstrap.sh              # входная точка, идемпотентная, «одна команда»
├── README.md
├── env.sh                    # общие переменные (IP, порты, пути)
│
├── system/                   # то, что кладётся в /system (переживает reset)
│   ├── hosts.append          # строки для /system/etc/hosts
│   ├── eth0_setup.append     # хвост для автозапуска
│   └── cacerts/
│       └── 7a0d056c.0        # наш CA (PEM)
│
├── certs/
│   ├── ca.crt                # CA (публичный)
│   ├── ca.key                # CA private (⚠️ приватный репозиторий!)
│   └── gen_server_cert.sh    # генерит server.pem под hub2.lifecontrol.ru
│
├── proxy/                    # эмулятор облака (Python, крутится в chroot)
│   ├── httpproxy.py          # HTTP backend, порт 6666
│   ├── tlsproxy.py           # TLS 443 → 6666
│   └── openssl_legacy.cnf    # разрешает TLS 1.0 для старого Android
│
├── db/
│   └── patch_registration.py # RegStatus=1, AvailableServers=hub2...
│
├── chroot/
│   ├── build_chroot.sh       # debootstrap ИЛИ распаковка rootfs.tar.gz
│   ├── install_ha.sh         # HA 2023.1.7 + зависимости
│   └── packages/             # заранее скачанные .deb (socat и т.п.)
│
├── ha-config/                # конфиг Home Assistant (configuration.yaml…)
│
└── releases/                 # большие бинари через git-lfs или Releases
    └── debian-rootfs.tar.gz  # готовый chroot (быстрее debootstrap)
```

> **Приватность**: `ca.key` и любые сессионные секреты — только в приватном
> репозитории. Если репо публичный, `ca.key` не коммитить; генерить CA
> в `bootstrap.sh` и хранить хэш.

---

## 4. `bootstrap.sh` — дизайн «одной команды»

Запуск после reset/ребута (по ADB или из `eth0_setup`):

```sh
# одна команда на устройстве:
wget -O- https://raw.githubusercontent.com/<user>/alyt-restore/main/bootstrap.sh | sh
```

Логика (идемпотентная — можно гонять повторно):

```
1.  Окружение
    - mount -o remount,rw /system
    - echo 0 > /sys/fs/selinux/enforce         # permissive для chroot-сети
2.  busybox
    - если нет /data/busybox → wget из releases, chmod +x
3.  Репозиторий
    - если нет git → скачать tarball репо через wget, распаковать в /data/alyt-restore
4.  chroot
    - если нет /data/debian → chroot/build_chroot.sh
      (распаковать releases/debian-rootfs.tar.gz — быстро;
       fallback: debootstrap)
    - install_ha.sh если HA ещё не стоит
5.  /system-хвосты (только если ещё не добавлены — grep-guard)
    - hosts.append → /system/etc/hosts
    - cacerts/7a0d056c.0 → /system/etc/security/cacerts/
    - eth0_setup.append → /system/bin/eth0_setup
6.  Сертификаты
    - certs/gen_server_cert.sh → /data/debian/tmp/server.pem
7.  Прокси
    - killall python3 (чистка), запуск httpproxy.py + tlsproxy.py через nohup
8.  iptables-редиректы (nat OUTPUT на 95.163.244.135)
9.  Патч БД
    - db/patch_registration.py (после первого старта lytcentral)
10. Home Assistant
    - start_ha.sh (или уже стартует из eth0_setup)
11. Проверки
    - wget https://127.0.0.1/.../LYT_Login.php  → success
    - wget http://192.168.2.223:8080/WEB_API_login → OK
    - вывести статус каждого пункта
```

**Автозапуск при загрузке**: `eth0_setup.append` дописывает в
`/system/bin/eth0_setup` вызов `bootstrap.sh` (локальную копию из
`/data/alyt-restore`), чтобы после ребута всё поднималось само. После
factory reset `/data` пуст → первый запуск делается вручную по ADB (одна
команда выше), дальше самоподдерживается.

---

## 5. Эмулятор облака — рабочая конфигурация

**Мёртвый оригинал**: `hub2.lifecontrol.ru` → `95.163.244.135`, порты 80/443.

### Цепочка перехвата
```
lytcentral → hosts(127.0.0.1) / iptables(95.163.244.135)
           → :443 tlsproxy.py (TLS 1.0, наш CA)
           → :6666 httpproxy.py (отдаёт JSON)
```

### Эндпоинты (все POST, ответы уже подобраны и рабочие)
```
/ServerLYT/LYT_Server/LYT_ts_setup.php            → {"RESULT":"success","TIMESTAMP":<unix>}
/ServerLYT/LYT_Server/LYT_Login.php               → {"RESULT":"success","SERVERLIST_UPDATE":false}
/ServerLYT/LYT_Server/LYT_Registration_Status.php → {"RESULT":"success","USERNAME":"user_XXXX@alyt.lk2.lifecontrol.ru"}
/ServerLYT/LYT_Server/LYT_Servers_List.php        → {"RESULT":"success","SERVER_LIST":["hub2.lifecontrol.ru"]}
/ServerLYT/LYT_Server/LYT_Connection.php          → {"RESULT":"success","CMD_LIST":[]}
/ServerLYT/LYT_Server/LYT_Cloud_Commands.php      → {"RESULT":"success","CMD_LIST":[]}
/ServerLYT/LYT_Server/LYT_Default_Notifications.php → {"RESULT":"success"}
/ServerLYT/LYT_Server/LYT_Report.php              → {"RESULT":"success"}
/ServerLYT/LYT_Server/LYT_Event.php               → {"RESULT":"success"}
/ServerLYT/LYT_Server/LYT_Update_Name.php         → {"RESULT":"success"}
/ServerLYT/LYT_Server/LYT_Check_Version_Update.php → {"RESULT":"success","UPDATE_AVAILABLE":false}
```

### Достигнутый результат
`reachable? true` ✅ · облако не перечёркнуто ✅ · «сервис успешно
продлён» ✅. Остаётся `regstatus: null` (не блокирует базовую работу).

---

## 6. Ключевые грабли (собраны потом и кровью)

- **Двойной `https://`**: код сам добавляет `"https://"` к значению из БД.
  В `AvailableServers` хранить **голый хост** `hub2.lifecontrol.ru` без схемы.
- **`RegStatus` — строка** `"0"/"1"` в `ServerDataTable`, не int.
  Enum в коде: `NOT_REGISTERED(0)`, `REGISTERED(1)`.
- **Старый Android SSL** требует TLS 1.0 + слабые шифры →
  `OPENSSL_CONF=openssl_legacy.cnf`, `set_ciphers('ALL:@SECLEVEL=0')`,
  `minimum_version = TLSv1`. Иначе `unsupported protocol`.
- **Python в chroot не видит `/data/data`** → БД копировать в `/tmp`
  chroot, править sqlite3, копировать обратно.
- **busybox httpd не умеет POST** на статику (501) и требует auth на
  `/ServerLYT` (401) → используем свой `httpproxy.py`.
- **Порты уходят в TIME_WAIT** и «Address already in use» → не
  переиспользовать сразу, менять порт (7777→8888→6666…) или ждать.
- **`dpkg-deb` сегфолтит** на kernel 3.10 → распаковка .deb вручную
  (ar-заголовки парсить питоном; в chroot нет `xz` → `lzma`+`tarfile`).
- **Paranoid Networking**: сокеты в chroot только если процесс в группе
  `3003 (inet)` → `os.setgroups([0,3003,3004])` перед exec.
- **SELinux** → `echo 0 > /sys/fs/selinux/enforce` (permissive).
- **setuptools** пинить `≤67.8.0` (иначе нет `pkg_resources`).
- **`/system` remount rw** нужен после каждого ребута.
- Нет `curl/find/head/tail/which` — только busybox по полному пути
  `/data/busybox`.

### Грабли Фазы A (HA-сборка, собраны в v3.2)
- **rootfs rcn-ee БЕЗ pip/ensurepip** и с урезанным distutils (только
  `__init__.py`+`version.py`) -> pip ставить get-pip'ом, distutils —
  `deb-extract`. "Жирного" rootfs с pip под armhf практически не бывает.
- **`apt install` / `apt --fix-broken` мертвы** (dpkg-deb сегфолт). После
  ручной распаковки .deb НЕ звать `apt --fix-broken` — застрянет на
  security-апдейте python3.9. Сразу `apt-mark hold` python3.9-пакетов.
  Качать named-пакеты `apt-get download` (не строит resolver, переживает
  version-перекос), распаковывать `deb-extract`.
- **pillow**: `pip install --index-url piwheels --only-binary :all: pillow`
  (без пина — 9.3.0 колеса нет). Компиляция падает на zlib.
- **HA `--skip-pip` обязателен**, но зависимости тогда добирать вручную и
  пинить под 2023.1 (см. §9). pip при ручной доустановке всегда тянет latest.
- **Windows-консоль + heredoc**: любой python-скрипт через `python3 <<EOF`
  из Windows держать в ASCII (кириллица -> `Non-UTF-8 ... \x8f`). Сообщения
  скриптов — по-английски. `chcp` в Android-шелле нет.
- **`.tmp` при заливке**: Total Commander ADB-плагин пишет во временный файл
  и переименовывает; ждать финального имени. Нет pipe в `adb shell` (нужен
  обычный adb.exe для потоковой распаковки).
- **udev/маунты при удалении chroot**: сначала `pkill hass` + `umount -l`
  (busybox, у toybox нет `-l`), потом `rm`. Проще — reboot (маунты не persist).
  ПОСЛЕ ребута chroot-маунты уже подняты автозапуском.
- **start-скрипты**: писать через quoted heredoc (без chr()-кодирования);
  задавать `PATH` и `HOME=/root` в exec, иначе в chroot пустой PATH.

---

## 7. Локальный HTTP API хаба (порт 8080) — прямое управление

Работает **без облака**, это главный рычаг для управления устройствами.

```sh
# логин
wget -O- --post-data='username=admin&password=admin' \
  http://192.168.2.223:8080/WEB_API_login
# → {"RESULT":"OK"} ; cookie: alytsession={"WEBSESSION_ID":"..."}

# статус + список устройств
wget -O- --header="Cookie: $COOK" \
  http://192.168.2.223:8080/WEB_API_get_wifi_data

# Z-Wave
wget -O- --header="Cookie: $COOK" \
  --post-data='cmd={"CMD":"CMD00_GET_STATUS","PARAMS":[]}' \
  http://192.168.2.223:8080/WEB_API_zwave
```

### Z-Wave команды (`/WEB_API_zwave`, `cmd=<json>`)
```
CMD00_GET_STATUS                              список устройств (long-poll)
CMD01_ADD      PARAMS:["ADD"]                 inclusion
CMD02_REMOVE   PARAMS:["REMOVE"]              exclusion
CMD06_SWITCH_ON_OFF  PARAMS:[node,"SWITCH_ON"|"SWITCH_OFF"]
CMD09_BASIC_SET_ON_OFF PARAMS:[node,"BASIC_SET_ON"|"..._OFF"]
CMD10_GET_TEMPERATURE  PARAMS:[node]
CMD11_SET_TEMPERATURE  PARAMS:[node, value]
CMD14_GET_BATTERY_LEVEL PARAMS:[node]
CMD07_RESET / CMD08_SHIFT
```

Формат ответа: `{"RESULT":"OK","RESPONSE":{"STATUS":"IDLE","DEVICE_LIST":[…]}}`.

---

## 8. База данных lytcentral

`/data/data/it.takeoff.lytcentral/databases/LYT_ServerDataDb`

```sql
ServerDataTable:  LYTname | UserRemote | CodeID | RegStatus | RegCmdStatus | enableap
  ALYT_<XX:XX:XX> | user_XXXX@alyt.lk2.lifecontrol.ru | <CODE_ID> | 1 | 0 | 0
AvailableServers: ServerIP | LastChoosed
  hub2.lifecontrol.ru | 1          -- голый хост! LastChoosed="1" = текущий
```

Правится `db/patch_registration.py` (copy-in → sqlite3 → copy-out).

---

## 9. Home Assistant — воспроизводимая сборка Фазы A

HA **2023.1.7** в chroot `/data/debian/opt/ha` (venv). Порт **8123**.
Ставится `bootstrap.sh` -> `setup_chroot.sh` (v3.2) одной командой.

### Порядок установки (setup_chroot.sh)
1. pip — через **get-pip.py** (`bootstrap.pypa.io/pip/3.9/`), качать питоновым
   `urllib` (curl в rootfs нет). Минимальный rootfs идёт БЕЗ pip и ensurepip.
2. venv: `python3 -m venv /opt/ha --without-pip`, затем get-pip в venv
   (ensurepip сломан -> `--without-pip` обязателен).
3. distutils/setuptools/pkg_resources — через `deb-extract` в системный питон
   И `setuptools==67.8.0` отдельно в venv (даёт pkg_resources в venv).
4. **pillow — из piwheels ДО HA**: `--only-binary :all:` (9.3.0 колеса нет,
   ставится 11.x). Иначе HA компилирует pillow и падает на отсутствии zlib.
5. HA: `pip install homeassistant==2023.1.7`.

### Ключ: HA запускать с `--skip-pip`
Без флага HA при старте пытается доустановить пины (`pillow==9.3.0`) и падает.
Но `--skip-pip` тогда НЕ добирает честные зависимости -> их ставим вручную,
ВСЕ пинить под эпоху 2023.1 (latest ломает старый HA):
```
aiohttp==3.8.1  yarl==1.8.1          # re-pin ПОСЛЕДНИМ (другие install их задирают)
aiohttp_cors==0.7.0                  # 0.8+ требует aiohttp>=3.9 (web.AppKey)
sqlalchemy==1.4.44                   # 2.0 ломает recorder (Mapped[] annotations)
janus  fnvhash                       # тихие зависимости file_upload/analytics
home-assistant-frontend==20230110.0  # сам UI (имя пакета, НЕ hass-frontend)
```
+ системная `.so`: `deb-extract libopenjp2-7` (нужна pillow/image_upload).
Точную версию frontend брать из `frontend/manifest.json` -> `requirements`.

### Onboarding
В `configuration.yaml` сразу задать `country: RU`, `currency: RUB`,
`language: ru` — иначе onboarding падает `Failed to save: undefined`
(`invalid ISO 3166 country ... Got ''`).

### Вход в chroot
`sh /data/start_debian.sh` — ВАЖНО: скрипт задаёт `PATH` и `HOME=/root` в
`os.environ` перед exec bash (иначе python3/nano "не найдены" — PATH пустой,
а `~/.bashrc` не читается без HOME). Helper `ha-restart` (в chroot) — убить
залипший hass + старт.

### Автозапуск
`eth0_setup` -> `start_ha.sh &` (в фоне). Хук дописывать через **/data**,
НЕ /tmp (в Android-шелле /tmp нет — из-за этого хук молча не добавлялся).
apt-песочница отключена: `APT::Sandbox::User "root"`.

---

## 10. APK / декомпиляция

| Пакет | Файл | Роль |
|-------|------|------|
| `it.takeoff.lytcentral` | `/system/app/AlytHub.apk` | ядро: Z-Wave, ZigBee, облако |
| `it.alyt.launcher.launchermainactivity` | `/system/app/` | лаунчер/UI |
| `com.takeoff.lytwatchdog` | `/system/app/` | watchdog |

Декомпиляция: **jadx** на ПК —
`jadx-<ver>\bin\jadx.bat -d C:\out AlytHub.apk`
(из GUI кнопка иногда «молчит»; запускать батник/`java -jar`).
Поиск в исходниках через PowerShell:
```powershell
Get-ChildItem -Recurse -Filter "*.java" C:\out\sources |
  Select-String -Pattern "LYT_ts_setup|RegStatus|no server" |
  Select-Object Filename,LineNumber,Line
```

---

## 11. Дорожная карта

**Сейчас** (этот репозиторий): one-command bootstrap, самоподдержка
после reset/ребута.

**Далее — VPS-бэкенд**:
- Полноценный Debian на VPS, nginx + Let's Encrypt (настоящий TLS).
- Все эндпоинты из §5 как реальный сервис.
- Хаб направить на VPS через `/system/etc/hosts` (заменить 127.0.0.1
  на IP VPS) — тогда прокси в chroot не нужны.
- Мобильное приложение: декомпилировать, сменить URL, пересобрать,
  подписать → регистрация/добавление устройств «как раньше».

**Управление устройствами без облака**:
- Z-Wave — уже сейчас через `WEB_API_zwave` (§7).
- ZigBee (CC2538, ZNP по SPI) — через zigpy/ZHA напрямую (нужен мост
  SPI↔serial или reverse `/dev/lyt_zb_prog_data`).
- Интеграция в HA как backend, UI/голос (Яндекс Алиса —
  `dext0r/yandex_smart_home`, требует HA 2025.12+ / Python 3.13–3.14,
  конфликт с текущим Debian 11 — вынести в отдельный контейнер/VPS).

**Надёжность**:
- `releases/debian-rootfs.tar.gz` — мастер-образ chroot для быстрого
  восстановления.
- Полный readback флеша через **MediaTek SP Flash Tool** как recovery-мастер.

---

## 12. Чек-лист восстановления после factory reset

```
[ ] adb connect 192.168.2.223:5555   (после того как ADB поднимется)
[ ] mount -o remount,rw /system
[ ] wget -O- https://raw.githubusercontent.com/<user>/alyt-restore/main/bootstrap.sh | sh
[ ] bootstrap сам: busybox → repo → chroot → HA → /system-хвосты → прокси → iptables → patch DB
[ ] проверить: облако не перечёркнуто, HA на :8123, hub API на :8080
[ ] eth0_setup содержит вызов bootstrap → следующие ребуты автоматом
```