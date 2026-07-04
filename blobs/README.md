# Бинарные блобы

Эти файлы **не хранятся в git** (размер и лицензии) — скачай их перед
восстановлением и положи сюда, в `blobs/`. Дальше их заливает `adb push`
(см. корневой `README.md`, шаг 1).

## busybox (armv7l)
```
wget -O busybox-armv7l \
  https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv7l
```

## Debian 11 armhf rootfs
Из архива `debian-11.7-minimal-armhf-2023-08-22.tar.xz`:
```
tar -xJf debian-11.7-minimal-armhf-2023-08-22.tar.xz
cp debian-11.7-minimal-armhf-2023-08-22/armhf-rootfs-debian-bullseye.tar ./
```

## pip wheel
```
wget -O pip-24.0-py3-none-any.whl \
  https://files.pythonhosted.org/packages/py3/p/pip/pip-24.0-py3-none-any.whl
```

---

Крупные готовые артефакты (например, собранный `debian-rootfs.tar.gz` со
всем установленным HA) лучше отдавать через **GitHub Releases**, а не git —
лимит файла в git 100 МБ, rootfs больше.
