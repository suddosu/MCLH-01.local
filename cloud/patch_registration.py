#!/usr/bin/python3
# -*- coding: utf-8 -*-
# patch_registration.py - sets the hub status to "registered".
#
# Runs INSIDE chroot (python3 + sqlite3 present).
# chroot cannot see /data/data, so the DB is copied to /opt/cloud
# before this runs and copied back after.
#
# Usage (inside chroot):
#   python3 /opt/cloud/patch_registration.py /opt/cloud/LYT_ServerDataDb
#
# What it does:
#   ServerDataTable.RegStatus = "1"  (REGISTERED)
#   AvailableServers = [("hub2.lifecontrol.ru","1")] - BARE host!
#     (app prepends "https://" itself)

import sqlite3
import sys

SERVER_HOST = "hub2.lifecontrol.ru"   # no scheme!


def patch(db_path):
    db = sqlite3.connect(db_path)
    c = db.cursor()

    # --- Diagnostics: before ---
    try:
        c.execute("SELECT * FROM ServerDataTable")
        print("ServerDataTable BEFORE:", c.fetchall())
    except sqlite3.OperationalError as e:
        print("ServerDataTable: no table?", e)

    try:
        c.execute("SELECT * FROM AvailableServers")
        print("AvailableServers BEFORE:", c.fetchall())
    except sqlite3.OperationalError as e:
        print("AvailableServers: no table?", e)

    # --- RegStatus = "1" (string!) ---
    c.execute("UPDATE ServerDataTable SET RegStatus = '1'")

    # --- AvailableServers: single row, bare host, current="1" ---
    c.execute("DELETE FROM AvailableServers")
    c.execute(
        "INSERT INTO AvailableServers (ServerIP, LastChoosed) VALUES (?, ?)",
        (SERVER_HOST, "1"),
    )

    db.commit()

    # --- Diagnostics: after ---
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