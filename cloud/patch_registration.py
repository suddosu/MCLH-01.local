#!/usr/bin/python3
# -*- coding: utf-8 -*-
# patch_registration.py — выставляет хабу статус «зарегистрирован».
#
# ЗАПУСКАЕТСЯ ВНУТРИ chroot (там есть python3 + sqlite3).
# chroot НЕ видит /data/data, поэтому bootstrap копирует БД в /opt/cloud
# ДО запуска этого скрипта и копирует обратно ПОСЛЕ.
#
# Использование (внутри chroot):
#   python3 /opt/cloud/patch_registration.py /opt/cloud/LYT_ServerDataDb
#
# Что делает:
#   ServerDataTable.RegStatus = "1"                 (REGISTERED)
#   AvailableServers = [("hub2.lifecontrol.ru","1")] — ГОЛЫЙ хост!
#     (код приложения сам добавляет "https://" перед значением)

import sqlite3
import sys

SERVER_HOST = "hub2.lifecontrol.ru"   # без схемы!


def patch(db_path):
    db = sqlite3.connect(db_path)
    c = db.cursor()

    # --- Диагностика: что было ---
    try:
        c.execute("SELECT * FROM ServerDataTable")
        print("ServerDataTable BEFORE:", c.fetchall())
    except sqlite3.OperationalError as e:
        print("ServerDataTable: нет таблицы?", e)

    try:
        c.execute("SELECT * FROM AvailableServers")
        print("AvailableServers BEFORE:", c.fetchall())
    except sqlite3.OperationalError as e:
        print("AvailableServers: нет таблицы?", e)

    # --- RegStatus = "1" (строка!) ---
    c.execute("UPDATE ServerDataTable SET RegStatus = '1'")

    # --- AvailableServers: единственная запись, голый хост, current="1" ---
    c.execute("DELETE FROM AvailableServers")
    c.execute(
        "INSERT INTO AvailableServers (ServerIP, LastChoosed) VALUES (?, ?)",
        (SERVER_HOST, "1"),
    )

    db.commit()

    # --- Диагностика: что стало ---
    c.execute("SELECT RegStatus, RegCmdStatus FROM ServerDataTable")
    print("ServerDataTable AFTER (RegStatus,RegCmdStatus):", c.fetchall())
    c.execute("SELECT * FROM AvailableServers")
    print("AvailableServers AFTER:", c.fetchall())

    db.close()
    print("patch_registration: OK")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: patch_registration.py <path-to-LYT_ServerDataDb>")
        sys.exit(1)
    patch(sys.argv[1])
