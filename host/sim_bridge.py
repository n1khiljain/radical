"""
host/sim_bridge.py
Compiles the RTL (once, cached), launches vvp with the TCP VPI plugin,
and exposes the same read/write/stream_input/inject_bit_flip API as FakeChip.

Usage:
    from host.sim_bridge import SimBridge
    from host.driver import AcceleratorDriver

    chip   = SimBridge()           # compile + launch sim (blocks until READY)
    driver = AcceleratorDriver(chip)
    driver.load_weights("weights.bin")
    driver.run_inference(image_bytes)
"""

import os
import subprocess
import tempfile
from pathlib import Path

ROOT    = Path(__file__).parent.parent
SIM_BIN = ROOT / "sim_chip.vvp"

RTL_FILES = [
    "tb/tb_chip.sv", "rtl/chip.sv", "rtl/ctrl_seq.sv",
    "rtl/conv1_stage.sv", "rtl/conv2_stage.sv", "rtl/fc1_stage.sv", "rtl/fc2_stage.sv",
    "rtl/telemetry_regs.sv", "rtl/ecc_secded.sv", "rtl/weight_mem_ecc.sv", "rtl/weight_mem.sv",
]


class SimBridge:
    def __init__(self):
        self._tmp: list[str] = []

        self._compile_if_stale()
        self._launch()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def _compile_if_stale(self) -> None:
        if SIM_BIN.exists():
            mtime = SIM_BIN.stat().st_mtime
            if not any((ROOT / f).stat().st_mtime > mtime
                       for f in RTL_FILES if (ROOT / f).exists()):
                print(f"[sim_bridge] using cached {SIM_BIN.name}")
                return
        print("[sim_bridge] compiling RTL (~55s) ...")
        r = subprocess.run(["iverilog", "-g2012"] +
                           [str(ROOT / f) for f in RTL_FILES],
                           cwd=str(ROOT), capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"iverilog failed:\n{r.stderr}")
        (ROOT / "a.out").rename(SIM_BIN)
        print(f"[sim_bridge] compiled → {SIM_BIN.name}")

    def _launch(self) -> None:
        for p in (ROOT / "sim_cmd.fifo", ROOT / "sim_resp.fifo"):
            if p.exists():
                p.unlink()
            os.mkfifo(p)

        self._proc = subprocess.Popen(
            ["vvp", str(SIM_BIN)],
            cwd=str(ROOT),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Open command pipe for writing first — this unblocks sim's $fopen("r")
        self._cmd  = open(ROOT / "sim_cmd.fifo",  "w", buffering=1)
        # Then open response pipe for reading — unblocks sim's $fopen("w")
        self._resp = open(ROOT / "sim_resp.fifo", "r", buffering=1)

        ready = self._resp.readline().strip()
        if ready != "READY":
            raise RuntimeError(f"Expected READY from sim, got {ready!r}")
        print("[sim_bridge] sim ready")

    def close(self) -> None:
        try:
            self._cmd.write("QUIT\n")
            self._cmd.flush()
        except Exception:
            pass
        self._proc.wait(timeout=5)
        self._cmd.close()
        self._resp.close()
        for f in self._tmp:
            try: os.unlink(f)
            except FileNotFoundError: pass

    def __del__(self):
        try: self.close()
        except Exception: pass

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _send(self, line: str) -> str:
        self._cmd.write(line + "\n")
        self._cmd.flush()
        return self._resp.readline().strip()

    # ------------------------------------------------------------------
    # Public API  (FakeChip-compatible)
    # ------------------------------------------------------------------

    def read(self, addr: int) -> int:
        reply = self._send(f"READ {addr:08X}")
        if not reply.startswith("DATA"):
            raise RuntimeError(f"Bad READ reply: {reply!r}")
        return int(reply.split()[1], 16)

    def write(self, addr: int, val: int) -> None:
        reply = self._send(f"WRITE {addr:08X} {val:08X}")
        if reply != "OK":
            raise RuntimeError(f"Bad WRITE reply: {reply!r}")

    def stream_input(self, data: bytes) -> None:
        fd, path = tempfile.mkstemp(prefix="sim_stream_", dir=ROOT)
        self._tmp.append(path)
        os.write(fd, data)
        os.close(fd)
        # Use BACKDOOR_LOAD for weights.bin-sized blobs (fast hierarchical write).
        # Fall back to AXI-stream STREAM for image-sized payloads (784 bytes).
        if len(data) > 784:
            reply = self._send(f"BACKDOOR_LOAD {path}")
        else:
            reply = self._send(f"STREAM {len(data)} {path}")
        if reply != "OK":
            raise RuntimeError(f"Bad stream reply: {reply!r}")

    def inject_bit_flip(self, mem_id: int, addr: int, bit_idx: int) -> None:
        reply = self._send(f"INJECT {mem_id} {addr} {bit_idx}")
        if reply != "OK":
            raise RuntimeError(f"Bad INJECT reply: {reply!r}")
