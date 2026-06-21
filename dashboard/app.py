"""
dashboard/app.py  --  RAD-HARD-AI live demo

Streamlit dashboard that drives the behavioral accelerator under live fault
injection and shows, in real time:

  * predicted class vs the clean reference (correct / corrupted)
  * rolling accuracy for the current settings
  * telemetry counters (scrub corrections, double errors, TMR overrides)
  * a live feed of radiation events (also forwarded to Sentry)
  * the precomputed accuracy-vs-BER sweep curve

Run:  streamlit run dashboard/app.py

Sentry/Redis are optional and OFF by default (toggle in the sidebar). With no
servers configured they degrade gracefully to no-op / in-memory so the demo
always runs.
"""

import json
import os
import sys
import time

import streamlit as st

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mock.behavioral_chip import BehavioralChip
from host.driver import AcceleratorDriver
from injector.fault_injector import FaultInjector
from integrations.sentry_emit import SentryEmitter
from integrations.redis_bus import RedisBus

CYCLES_PER_INF = 2000

st.set_page_config(page_title="RAD-HARD-AI", page_icon="🛰️", layout="wide")


@st.cache_data
def load_reference():
    with open("reference_outputs.json") as f:
        return json.load(f)


def init_state():
    if "chip" in st.session_state:
        return
    st.session_state.chip = BehavioralChip()
    st.session_state.driver = AcceleratorDriver(st.session_state.chip)
    st.session_state.injector = FaultInjector(st.session_state.chip, ber=0.0)
    st.session_state.sentry = SentryEmitter(enabled=bool(os.environ.get("SENTRY_DSN")))
    st.session_state.redis = RedisBus(enabled=False)
    st.session_state.running = False
    st.session_state.cursor = 0
    st.session_state.n_total = 0
    st.session_state.n_correct = 0
    st.session_state.events = []          # recent decoded events for the feed


def reset_run():
    st.session_state.chip.reset_faults()
    st.session_state.chip.reset_counters()
    st.session_state.cursor = 0
    st.session_state.n_total = 0
    st.session_state.n_correct = 0
    st.session_state.events = []


def run_batch(ref, batch=5):
    chip, drv, inj = (st.session_state.chip, st.session_state.driver,
                      st.session_state.injector)
    sentry, redis = st.session_state.sentry, st.session_state.redis
    last_pred = last_exp = None
    for _ in range(batch):
        entry = ref[st.session_state.cursor % len(ref)]
        st.session_state.cursor += 1
        inj.tick(CYCLES_PER_INF)
        drv.run_inference(bytes(entry["input_bytes"]))
        pred = drv.read_result()
        last_pred, last_exp = pred, entry["expected_class"]
        st.session_state.n_total += 1
        st.session_state.n_correct += int(pred == entry["expected_class"])

        # drain radiation events -> Sentry + local feed
        while True:
            ev = drv.pop_event()
            if ev is None:
                break
            sentry.emit_event(ev)
            st.session_state.events.append(ev)
        st.session_state.events = st.session_state.events[-12:]

    redis.publish(drv.read_telemetry())
    return last_pred, last_exp


init_state()
ref = load_reference()

# ----------------------------------------------------------------------------
# Sidebar controls
# ----------------------------------------------------------------------------
st.sidebar.title("🛰️ RAD-HARD-AI")
st.sidebar.caption("Radiation-hardened INT8 CNN inference accelerator")

hardened = st.sidebar.toggle("Hardening enabled (ECC + scrubber + TMR)", value=True)
ber = st.sidebar.select_slider(
    "Injected bit-error rate",
    options=[0.0, 0.003, 0.01, 0.03, 0.1, 0.2, 0.4],
    value=0.03,
)
st.session_state.driver.set_hardening(hardened)
st.session_state.driver.set_scrubber(hardened)
st.session_state.injector.set_ber(ber)

c1, c2 = st.sidebar.columns(2)
if c1.button("▶ Run" if not st.session_state.running else "⏸ Pause", use_container_width=True):
    st.session_state.running = not st.session_state.running
if c2.button("↺ Reset", use_container_width=True):
    reset_run()
    st.session_state.running = False

st.sidebar.divider()
st.sidebar.write(f"**Sentry:** {'live' if st.session_state.sentry.enabled else 'offline (no DSN)'}")
st.sidebar.write(f"**Redis:** {'connected' if st.session_state.redis.connected else 'in-memory'}")

# ----------------------------------------------------------------------------
# Main panel
# ----------------------------------------------------------------------------
st.title("Live radiation-tolerance demo")

if st.session_state.running:
    last_pred, last_exp = run_batch(ref)
else:
    last_pred = last_exp = None

tel = st.session_state.driver.read_telemetry()
acc = (st.session_state.n_correct / st.session_state.n_total) if st.session_state.n_total else 1.0

m1, m2, m3, m4 = st.columns(4)
m1.metric("Mode", "HARDENED" if hardened else "BASELINE")
m2.metric("Inferences", f"{st.session_state.n_total}")
m3.metric("Accuracy vs reference", f"{acc:.0%}")
m4.metric("Corrupted weight bytes", f"{st.session_state.chip.corrupted_weight_bytes}")

st.subheader("Radiation telemetry")
t1, t2, t3, t4 = st.columns(4)
t1.metric("Scrub corrections", tel["scrub_corrections"])
t2.metric("ECC double errors", tel["ecc_double_errors"])
t3.metric("TMR overrides", tel["tmr_disagreements"])
t4.metric("Total inferences", tel["inferences_total"])

left, right = st.columns([1, 1])

with left:
    st.subheader("Live event feed")
    if st.session_state.events:
        names = {0: "🟢 SCRUB_CORRECT", 1: "🔴 ECC_UNCORRECTABLE", 2: "🟡 TMR_OVERRIDE"}
        rows = []
        for packed in reversed(st.session_state.events):
            rows.append({
                "type": names.get(packed & 0x3, "?"),
                "addr": f"0x{(packed >> 2) & 0xFFFF:04X}",
                "cycle": (packed >> 18) & 0x3FFF,
            })
        st.dataframe(rows, use_container_width=True, hide_index=True)
    else:
        st.info("No events yet — enable hardening and inject faults.")

with right:
    st.subheader("Accuracy vs BER (sweep)")
    if os.path.exists("sweep_accuracy.png"):
        st.image("sweep_accuracy.png", use_container_width=True)
    else:
        st.info("Run `python -m host.sweep` to generate the curve.")

# Auto-advance the loop while running.
if st.session_state.running:
    time.sleep(0.4)
    st.rerun()
