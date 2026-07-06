#!/usr/bin/python3
# -*- coding: utf-8 -*-
# ALYT cloud emulator - HTTP backend
# Runs INSIDE chroot, listens 0.0.0.0:6666, returns the JSON responses
# that it.takeoff.lytcentral expects from hub2.lifecontrol.ru.
#
# Start (from bootstrap, inside chroot):
#   nohup python3 /opt/cloud/httpproxy.py > /opt/cloud/http.log 2>&1 &
#
# Port 6666 chosen because 7777/8888/9999 went into TIME_WAIT during
# debugging. If 6666 is busy ("Address already in use") change PORT here
# and in tlsproxy.py (BACKEND_PORT) and the iptables redirect.

import socket
import threading
import time

PORT = 6666
LOG = "/opt/cloud/req_log.txt"

# Username from ServerDataTable.UserRemote (see patch_registration.py)
USERNAME = "user_5541@alyt.lk2.lifecontrol.ru"

# Bare host - same as in AvailableServers (no scheme!)
SERVER_HOST = "hub2.lifecontrol.ru"


def build_body(path):
    """Return the JSON response string for the given request path."""
    if "ts_setup" in path:
        return '{"RESULT":"success","TIMESTAMP":%d}' % int(time.time())
    if "Registration_Status" in path:
        return '{"RESULT":"success","USERNAME":"%s"}' % USERNAME
    if "Servers_List" in path:
        return '{"RESULT":"success","SERVER_LIST":["%s"]}' % SERVER_HOST
    if "Login" in path:
        return '{"RESULT":"success","SERVERLIST_UPDATE":false}'
    if "Connection" in path:
        return '{"RESULT":"success","CMD_LIST":[]}'
    if "Cloud_Commands" in path:
        return '{"RESULT":"success","CMD_LIST":[]}'
    if "Check_Version_Update" in path:
        return '{"RESULT":"success","UPDATE_AVAILABLE":false}'
    # Default_Notifications, Report, Event, Update_Name and everything else
    return '{"RESULT":"success"}'


def handle(conn):
    try:
        conn.settimeout(5)
        data = b""
        # Read until end of headers. POST body not needed for the response,
        # so we do not wait for Content-Length - faster, no hang.
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

        # Request log - helps when debugging new endpoints
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