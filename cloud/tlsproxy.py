#!/usr/bin/python3
# -*- coding: utf-8 -*-
# ALYT cloud emulator - TLS terminator
# Runs INSIDE chroot, listens 0.0.0.0:443, terminates TLS with our
# cert and forwards decrypted HTTP to 127.0.0.1:6666.
#
# Old Android SSL stack (it.takeoff.lytcentral) only speaks TLS 1.0
# and weak ciphers, so OPENSSL_CONF=openssl_legacy.cnf and
# SECLEVEL=0 are required, else handshake fails 'unsupported protocol'.
#
# Start (from bootstrap, inside chroot):
#   OPENSSL_CONF=/opt/cloud/openssl_legacy.cnf \
#     nohup python3 /opt/cloud/tlsproxy.py > /opt/cloud/tls.log 2>&1 &

import socket
import ssl
import threading

LISTEN_PORT = 443
BACKEND_HOST = "127.0.0.1"
BACKEND_PORT = 6666
CERT_PEM = "/opt/cloud/server.pem"   # cert + key in one file


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
    # Allow weak ciphers (needed by old Android)
    ctx.set_ciphers("ALL:@SECLEVEL=0")
    # Lift bans on old protocols
    ctx.options &= ~ssl.OP_NO_TLSv1
    ctx.options &= ~ssl.OP_NO_TLSv1_1
    try:
        ctx.minimum_version = ssl.TLSVersion.TLSv1
    except (ValueError, AttributeError):
        # Old OpenSSL builds may not support explicit setting -
        # then the minimum comes from openssl_legacy.cnf
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
            # Broken handshake - ignore, do not crash the server
            try:
                conn.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()