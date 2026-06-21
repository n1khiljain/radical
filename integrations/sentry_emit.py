"""
integrations/sentry_emit.py

Drains the chip's radiation-event FIFO and forwards every event to Sentry.

Each EVENT_POP that isn't zero becomes a Sentry event, tagged with the event
type and the affected memory address, at a severity that reflects how bad it is:

    SCRUB_CORRECT     -> info     (ECC caught and fixed a single-bit upset)
    TMR_OVERRIDE      -> warning  (a MAC produced a wrong value, voted out)
    ECC_UNCORRECTABLE -> error    (double-bit error; data is actually wrong)

Offline-safe: if no DSN is configured (or sentry_sdk isn't installed), it runs
in a no-op mode that still counts events, so the demo and tests work without a
network connection.
"""

import os

# type string -> Sentry level
SEVERITY = {
    "SCRUB_CORRECT":     "info",
    "TMR_OVERRIDE":      "warning",
    "ECC_UNCORRECTABLE": "error",
}


class SentryEmitter:
    def __init__(self, dsn: str | None = None, enabled: bool | None = None,
                 environment: str = "rad-hard-demo") -> None:
        self.dsn = dsn or os.environ.get("SENTRY_DSN")
        self.enabled = bool(self.dsn) if enabled is None else enabled
        self.emitted = 0
        self.by_level: dict[str, int] = {"info": 0, "warning": 0, "error": 0}
        self._sdk = None

        if self.enabled and self.dsn:
            try:
                import sentry_sdk
                sentry_sdk.init(dsn=self.dsn, environment=environment,
                                traces_sample_rate=0.0)
                self._sdk = sentry_sdk
            except Exception as e:                      # offline / bad DSN
                print(f"[sentry] disabled: {e}")
                self.enabled = False

    def emit_event(self, event: dict) -> str:
        """Forward one decoded event (from AcceleratorDriver.pop_event)."""
        level = SEVERITY.get(event["type"], "info")
        self.emitted += 1
        self.by_level[level] = self.by_level.get(level, 0) + 1

        if self._sdk is not None:
            with self._sdk.push_scope() as scope:
                scope.set_tag("type", event["type"])
                scope.set_tag("addr", f"0x{event['addr']:X}")
                scope.set_extra("timestamp", event["timestamp"])
                self._sdk.capture_message(
                    f"Radiation event: {event['type']} @ addr 0x{event['addr']:X}",
                    level=level,
                )
        return level

    def drain(self, driver, limit: int = 10_000) -> int:
        """Pop and forward every pending event from the chip. Returns count."""
        n = 0
        while n < limit:
            ev = driver.pop_event()
            if ev is None:
                break
            self.emit_event(ev)
            n += 1
        return n


if __name__ == "__main__":
    # Demo against the behavioral chip under faults (no DSN needed).
    from mock.behavioral_chip import BehavioralChip
    from host.driver import AcceleratorDriver
    from injector.fault_injector import FaultInjector

    chip = BehavioralChip()
    drv = AcceleratorDriver(chip)
    drv.set_hardening(True)
    drv.set_scrubber(True)
    inj = FaultInjector(chip, ber=0.05)

    em = SentryEmitter(enabled=False)               # force offline for the demo
    inj.tick(2000)
    drv.run_inference(bytes(784))
    print(f"drained {em.drain(drv)} events  by_level={em.by_level}")
