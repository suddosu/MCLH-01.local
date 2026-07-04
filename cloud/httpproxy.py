#!/usr/bin/python3
# -*- coding: utf-8 -*-
# ALYT cloud emulator — HTTP backend
# Крутится ВНУТРИ chroot, слушает 0.0.0.0:6666, отдаёт JSON-ответы,
# которые ожидает it.takeoff.lytcentral от hub2.lifecontrol.ru.
#
# Запуск (из bootstrap, внутри chroot):
#   nohup python3 /opt/cloud/httpproxy.py > /opt/cloud/http.log 2>&1 &
#
# Порт 6666 выбран потому, что 7777/8888/9999 уходили в TIME_WAIT в ходе
# отладки. Если 6666 занят («Address already in use») — поменяй PORT здесь
# и в tlsproxy.py (BACKEND_PORT), и в iptables-редиректе.

import socket
import threading
import time

PORT = 6666
LOG = "/opt/cloud/req_log.txt"

# Имя пользователя из ServerDataTable.UserRemote (см. db/patch_registration.py)
USERNAME = "user_5541@alyt.lk2.lifecontrol.ru"

# Голый хост — тот же, что в AvailableServers (без схемы!)
SERVER_HOST = "hub2.lifecontrol.ru"


def build_body(path):
    """Возвращает JSON-строку ответа для данного пути запроса."""
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
    # Default_Notifications, Report, Event, Update_Name и всё прочее
    return '{"RESULT":"success"}'


def handle(conn):
    try:
        conn.settimeout(5)
        data = b""
        # Читаем до конца заголовков. Тело POST нам не нужно для ответа,
        # поэтому не ждём Content-Length — это ускоряет и не виснет.
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

        # Лог запросов — помогает при отладке новых эндпоинтов
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
