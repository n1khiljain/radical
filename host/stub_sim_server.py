"""
host/stub_sim_server.py
Minimal TCP server that mimics the RTL simulation protocol.
Use this to test sim_backend.py without a real simulator running.

Usage:
    Terminal 1:  python3 host/stub_sim_server.py
    Terminal 2:  python3 host/sim_backend.py
"""

import socket
import struct

HOST = "localhost"
PORT = 9000

# Fake register file — 256 x uint32
_regs: dict[int, int] = {}


def handle_client(conn: socket.socket, addr):
    print(f"[stub] Client connected: {addr}")
    f = conn.makefile("rwb", buffering=0)

    try:
        while True:
            line = f.readline().decode().strip()
            if not line:
                break

            print(f"[stub] ← {line!r}")
            parts = line.split()
            cmd = parts[0].upper()

            if cmd == "WRITE" and len(parts) == 3:
                reg_addr = int(parts[1], 16)
                val      = int(parts[2], 16)
                _regs[reg_addr] = val & 0xFFFFFFFF
                reply = "OK\n"

            elif cmd == "READ" and len(parts) == 2:
                reg_addr = int(parts[1], 16)
                val = _regs.get(reg_addr, 0)
                reply = f"DATA 0x{val:08X}\n"

            elif cmd == "STREAM" and len(parts) == 2:
                n_bytes = int(parts[1])
                raw = b""
                while len(raw) < n_bytes:
                    chunk = conn.recv(n_bytes - len(raw))
                    if not chunk:
                        break
                    raw += chunk
                print(f"[stub]   received {len(raw)} bytes of stream data")
                reply = "OK\n"

            elif cmd == "INJECT" and len(parts) == 4:
                mem_id  = int(parts[1])
                inj_addr = int(parts[2])
                bit_idx = int(parts[3])
                print(f"[stub]   inject bit-flip: mem={mem_id} addr={inj_addr} bit={bit_idx}")
                reply = "OK\n"

            else:
                reply = f"ERR unknown command: {line!r}\n"

            print(f"[stub] → {reply.strip()!r}")
            conn.sendall(reply.encode())

    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        conn.close()
        print(f"[stub] Client disconnected: {addr}")


def main():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT))
        srv.listen(1)
        print(f"[stub] Listening on {HOST}:{PORT}  (Ctrl-C to stop)")
        while True:
            conn, addr = srv.accept()
            handle_client(conn, addr)   # single-threaded; one client at a time


if __name__ == "__main__":
    main()
