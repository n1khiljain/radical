from integrations.sentry_emit import SentryEmitter, SEVERITY
from integrations.redis_bus import RedisBus


# --- Sentry emitter (offline mode) -----------------------------------------

def test_severity_mapping():
    assert SEVERITY["SCRUB_CORRECT"] == "info"
    assert SEVERITY["TMR_OVERRIDE"] == "warning"
    assert SEVERITY["ECC_UNCORRECTABLE"] == "error"


def test_emitter_offline_counts_events():
    em = SentryEmitter(enabled=False)
    assert not em.enabled
    lvl = em.emit_event({"type": "ECC_UNCORRECTABLE", "addr": 0x10, "timestamp": 1})
    assert lvl == "error"
    assert em.emitted == 1
    assert em.by_level["error"] == 1


def test_emitter_drain_pulls_all_events():
    class FakeDriver:
        def __init__(self):
            self.queue = [
                {"type": "SCRUB_CORRECT", "addr": 1, "timestamp": 0},
                {"type": "TMR_OVERRIDE", "addr": 2, "timestamp": 0},
            ]
        def pop_event(self):
            return self.queue.pop(0) if self.queue else None

    em = SentryEmitter(enabled=False)
    n = em.drain(FakeDriver())
    assert n == 2
    assert em.by_level == {"info": 1, "warning": 1, "error": 0}


# --- Redis bus (in-memory fallback) ----------------------------------------

def test_redis_in_memory_roundtrip():
    bus = RedisBus(enabled=False)
    assert not bus.connected
    bus.publish({"scrub_corrections": 5, "ecc_double_errors": 2})
    assert bus.get("scrub_corrections") == 5
    assert bus.snapshot() == {"scrub_corrections": 5, "ecc_double_errors": 2}


def test_redis_get_missing_is_zero():
    bus = RedisBus(enabled=False)
    assert bus.get("does_not_exist") == 0
