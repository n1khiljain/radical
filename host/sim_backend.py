"""
host/sim_backend.py
TCP backend that talks to a running RTL simulation.
Exposes the same API as mock/fake_chip.py.
"""

import socket


class SimBackend:
    def __init__(self, host: str = "localhost", port: int = 9000):
        try:
            self._sock = socket.create_connection((host, port), timeout=5)
            self._file = self._sock.makefile("rwb", buffering=0)
        except OSError as e:
            raise ConnectionError(
                f"Could not connect to RTL simulation at {host}:{port}. "
                f"Is the simulator listening? (Original error: {e})"
            ) from e

    # ------------------------------------------------------------------
    # Internal helper
    # ------------------------------------------------------------------
    def _send(self, cmd: str) -> str:
        """Send a text command line, return the reply line (stripped)."""
        self._sock.sendall(cmd.encode())
        reply = self._file.readline().decode().strip()
        if not reply:
            raise RuntimeError("No reply from simulation (connection closed?).")
        if not (reply.startswith("OK") or reply.startswith("DATA")):
            raise RuntimeError(f"Unexpected reply from simulation: {reply!r}")
        return reply

    # ------------------------------------------------------------------
    # Public API (mirrors mock/fake_chip.py)
    # ------------------------------------------------------------------
    def read(self, addr: int) -> int:
        """Read a 32-bit register. Returns uint32 value."""
        reply = self._send(f"READ 0x{addr:08X}\n")
        # Expected: "DATA 0x00000000"
        parts = reply.split()
        if len(parts) != 2 or parts[0] != "DATA":
            raise RuntimeError(f"Malformed DATA reply: {reply!r}")
        return int(parts[1], 16)

    def write(self, addr: int, val: int) -> None:
        """Write a 32-bit value to a register address."""
        self._send(f"WRITE 0x{addr:08X} 0x{val:08X}\n")

    def stream_input(self, data: bytes) -> None:
        """Stream raw bytes to the simulation (e.g. 784 bytes for MNIST)."""
        header = f"STREAM {len(data)}\n".encode()
        self._sock.sendall(header + data)
        reply = self._file.readline().decode().strip()
        if not reply.startswith("OK"):
            raise RuntimeError(f"STREAM command failed: {reply!r}")

    def inject_bit_flip(self, mem_id: int, addr: int, bit_idx: int) -> None:
        """Inject a single-bit fault into simulation memory."""
        self._send(f"INJECT {mem_id} {addr} {bit_idx}\n")

    def close(self) -> None:
        """Cleanly close the TCP connection."""
        try:
            self._file.close()
            self._sock.close()
        except OSError:
            pass


# ----------------------------------------------------------------------
# Smoke test — python3 host/sim_backend.py
# ----------------------------------------------------------------------
if __name__ == "__main__":
    print("Connecting to localhost:9000 …")
    sim = SimBackend("localhost", 9000)

    print("Writing 0x00000005 → address 0x00")
    sim.write(0x00, 0x00000005)

    val = sim.read(0x00)
    print(f"Read back from 0x00: 0x{val:08X} ({val})")

    print("Streaming 784 zero bytes …")
    sim.stream_input(bytes(784))

    sim.close()
    print("Done — connection closed cleanly.")
