"""
integrations/redis_bus.py

Telemetry buffer between the chip sim and the dashboard.

The host writes counter snapshots to Redis keys `telemetry:{name}`; the dashboard
reads from Redis instead of polling the chip directly, which decouples the two
(the dashboard keeps rendering even if a sweep is mid-flight).

Offline-safe: if no Redis server is reachable, it transparently falls back to an
in-process dict so the demo and tests run without `redis-server`.
"""

import os

NAMESPACE = "telemetry"


class RedisBus:
    def __init__(self, url: str | None = None, namespace: str = NAMESPACE,
                 enabled: bool | None = None) -> None:
        self.url = url or os.environ.get("REDIS_URL", "redis://localhost:6379/0")
        self.ns = namespace
        self._client = None
        self._store: dict[str, str] = {}        # in-memory fallback

        want = True if enabled is None else enabled
        if want:
            try:
                import redis
                client = redis.from_url(self.url, socket_connect_timeout=0.5)
                client.ping()
                self._client = client
            except Exception as e:
                print(f"[redis] using in-memory fallback: {e}")

    @property
    def connected(self) -> bool:
        return self._client is not None

    def _key(self, name: str) -> str:
        return f"{self.ns}:{name}"

    def publish(self, counters: dict) -> None:
        """Write a telemetry counter snapshot."""
        for name, value in counters.items():
            key = self._key(name)
            if self._client is not None:
                self._client.set(key, value)
            else:
                self._store[key] = str(value)

    def get(self, name: str) -> int:
        key = self._key(name)
        if self._client is not None:
            raw = self._client.get(key)
        else:
            raw = self._store.get(key)
        return int(raw) if raw is not None else 0

    def snapshot(self) -> dict:
        """Read back every telemetry counter as a dict."""
        if self._client is not None:
            keys = self._client.keys(f"{self.ns}:*")
            out = {}
            for k in keys:
                name = (k.decode() if isinstance(k, bytes) else k).split(":", 1)[1]
                out[name] = self.get(name)
            return out
        return {k.split(":", 1)[1]: int(v) for k, v in self._store.items()}


if __name__ == "__main__":
    bus = RedisBus()
    print(f"connected to redis: {bus.connected}")
    bus.publish({"scrub_corrections": 42, "ecc_double_errors": 3})
    print("snapshot:", bus.snapshot())
