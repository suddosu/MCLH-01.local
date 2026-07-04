#!/usr/bin/python3
# -*- coding: utf-8 -*-
# ALYT cloud emulator — TLS terminator
# Крутится ВНУТРИ chroot, слушает 0.0.0.0:443, терминирует TLS нашим
# сертификатом и форвардит расшифрованный HTTP на 127.0.0.1:6666.
#
# Старый Android SSL-стек (it.takeoff.lytcentral) умеет только TLS 1.0
# и слабые шифры, поэтому нужен OPENSSL_CONF=openssl_legacy.cnf и
# SECLEVEL=0 — иначе handshake падает с 'unsupported protocol'.
#
# Запуск (из bootstrap, внутри chroot):
#   OPENSSL_CONF=/opt/cloud/openssl_legacy.cnf \
#     nohup python3 /opt/cloud/tlsproxy.py > /opt/cloud/tls.log 2>&1 &

import socket
import ssl
import threading

LISTEN_PORT = 443
BACKEND_HOST = "127.0.0.1"
BACKEND_PORT = 6666
CERT_PEM = "/opt/cloud/server.pem"   # cert + key в одном файле


def handle(conn):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk:
                break
            req += chunk
        backend = socket.create_connection((BACKEND_HOST, BACKEND_PORT))
        backend.sendall(req)
        while True:
            data = backend.recv(4096)
            if not data:
                break
            conn.sendall(data)
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def build_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_PEM)
    # Разрешаем слабые шифры (нужно старому Android)
    ctx.set_ciphers("ALL:@SECLEVEL=0")
    # Снимаем запреты на старые протоколы
    ctx.options &= ~ssl.OP_NO_TLSv1
    ctx.options &= ~ssl.OP_NO_TLSv1_1
    try:
        ctx.minimum_version = ssl.TLSVersion.TLSv1
    except (ValueError, AttributeError):
        # Старые сборки OpenSSL могут не поддерживать явное задание —
        # тогда минимум задаётся через openssl_legacy.cnf
        pass
    return ctx


def main():
    ctx = build_context()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(20)
    print("tlsproxy: TLS %d -> %s:%d" % (LISTEN_PORT, BACKEND_HOST, BACKEND_PORT),
          flush=True)
    while True:
        conn, _ = srv.accept()
        try:
            tls = ctx.wrap_socket(conn, server_side=True)
            threading.Thread(target=handle, args=(tls,), daemon=True).start()
        except Exception:
            # Битый handshake — просто игнорируем, не роняем сервер
            try:
                conn.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
