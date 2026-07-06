#!/usr/bin/python3
# -*- coding: utf-8 -*-
# ALYT cloud emulator - HTTP backend (CORRECTED per jadx decompile)
# Runs INSIDE chroot, listens 0.0.0.0:6666, returns JSON that
# it.takeoff.lytcentral expects from hub2.lifecontrol.ru.
#
# All response formats below are VERIFIED against the decompiled parsers,
# not guessed. Key sources:
#   C0866a.m5521a  -> Servers_List: {"SERVERS_LIST":[{"URL":"..."}]}
#   C0885t.m5593a  -> Registration_Status: {"USERNAME":"..."} on success
#   C0880o.m5582a  -> Get_Settings: {"DATA":"..."} on success
#   C0862a.mo5492a -> Login: RESULT==success
#   C0868c.m5529a  -> Connection(poll): SERVERLIST_UPDATE bool + CMD_LIST
#   C0891z.m5616a  -> Default_Notifications: RESULT==success
#
# Start (inside chroot):
#   nohup python3 /opt/cloud/httpproxy.py > /opt/cloud/http.log 2>&1 &

import socket
import threading
import time

PORT = 6666
LOG = "/opt/cloud/req_log.txt"

# From ServerDataTable.UserRemote (see patch_registration.py)
USERNAME = "user_5541@alyt.lk2.lifecontrol.ru"

# BARE host - same value stored in AvailableServers (code prepends https://)
SERVER_HOST = "hub2.lifecontrol.ru"

# CC1110 frequency blob returned via Get_Settings(POST_FILTER=CC1110_FREQ).
# Parsed by C0880o as jSONObject.getString("DATA"), then decoded by
# C0899b.m5668a(String) into bytes. Empty string is accepted: the state
# machine in C0898a.m5664b() falls through GET_FREQUENCIES_FROM_CLOUD ->
# SEND_FREQUENCIES_TO_CLOUD -> uses the value already in the CC1110 fw,
# so returning success with empty DATA lets the radio init proceed using
# on-chip frequencies instead of blocking. If you later capture the real
# blob from a working hub, put its exact string here.
CC1110_FREQ_DATA = ""


def build_body(path):
    """Return the JSON body for a given request path.

    Formats are exact per decompiled parsers - do not 'simplify'.
    """
    # --- Time sync (C0787a): needs RESULT + TIMESTAMP ---
    if "ts_setup" in path:
        return '{"RESULT":"success","TIMESTAMP":%d}' % int(time.time())

    # --- Registration status (C0885t): success + USERNAME => REG ---
    if "Registration_Status" in path:
        return '{"RESULT":"success","USERNAME":"%s"}' % USERNAME

    # --- Server list (C0866a): SERVERS_LIST (with S!) array of {URL} ---
    #     WRONG (old): {"SERVER_LIST":["hub2..."]}
    #     RIGHT:       {"SERVERS_LIST":[{"URL":"hub2..."}]}
    if "Servers_List" in path:
        return ('{"RESULT":"success","SERVERS_LIST":[{"URL":"%s"}]}'
                % SERVER_HOST)

    # --- Login (C0862a): only RESULT==success is checked ---
    if "Login" in path:
        return '{"RESULT":"success"}'

    # --- Get_Settings (C0880o): success + DATA. Handles CC1110_FREQ ---
    if "Get_Settings" in path:
        return '{"RESULT":"success","DATA":"%s"}' % CC1110_FREQ_DATA

    # --- Polling (C0868c): SERVERLIST_UPDATE must be false, empty CMD_LIST ---
    #     If SERVERLIST_UPDATE=true, app triggers server-switch (m3200a) and
    #     can wipe LastChoosed -> "no server available" loop. Keep it false.
    if "Connection" in path:
        return '{"RESULT":"success","SERVERLIST_UPDATE":false,"CMD_LIST":[]}'
    if "Cloud_Commands" in path:
        return '{"RESULT":"success","CMD_LIST":[]}'

    # --- Version check (C0872g) ---
    if "Check_Version_Update" in path:
        return '{"RESULT":"success","UPDATE_AVAILABLE":false}'

    # --- MSISDN getters (C0879n) - return empty but success ---
    if "Get_MSISDN" in path:
        return '{"RESULT":"success","MSISDN":""}'

    # Default_Notifications, Report, Event, Update_Name, Notifications,
    # Network_Problems, Set_*, etc. - all only check RESULT==success
    return '{"RESULT":"success"}'


def handle(conn):
    try:
        conn.settimeout(5)
        data = b""
        while b"\r\n\r\n" not in data:
            try:
                chunk = conn.recv(1024)
                if not chunk:
                    break
                data += chunk
            except socket.timeout:
                break

        text = data.decode("utf-8", errors="replace")
        path = "/"
        first = text.split("\r\n", 1)[0]
        parts = first.split(" ")
        if len(parts) > 1:
            path = parts[1]

        try:
            with open(LOG, "a") as f:
                f.write(time.strftime("%H:%M:%S") + " " + path + "\n")
        except Exception:
            pass

        body = build_body(path)
        resp = (
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: %d\r\n"
            "Connection: close\r\n"
            "\r\n"
            "%s"
        ) % (len(body), body)
        conn.sendall(resp.encode())
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(50)
    print("httpproxy: HTTP backend on 0.0.0.0:%d" % PORT, flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
