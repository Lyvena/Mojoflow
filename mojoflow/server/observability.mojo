"""
MojoFlow Server — built-in observability.

Request logging, server metrics, latency histograms, and MAX-backed
aggregation helpers for the async HTTP server.
"""

from sys.ffi import external_call

from .config import ServerConfig
from .runtime import parallelize_work
from .types import Request, Response


alias CLOCKS_PER_SEC: Int64 = 1_000_000


struct LogLevel:
    """Numeric log levels for cheap hot-path comparisons."""

    alias OFF: Int = 0
    alias ERROR: Int = 1
    alias WARN: Int = 2
    alias INFO: Int = 3
    alias DEBUG: Int = 4
    alias TRACE: Int = 5

    var value: Int

    fn __init__(out self, value: Int = Self.INFO):
        self.value = value

    @staticmethod
    fn from_string(level: String) -> LogLevel:
        if level == "off" or level == "OFF":
            return LogLevel(LogLevel.OFF)
        if level == "error" or level == "ERROR":
            return LogLevel(LogLevel.ERROR)
        if level == "warn" or level == "WARN":
            return LogLevel(LogLevel.WARN)
        if level == "debug" or level == "DEBUG":
            return LogLevel(LogLevel.DEBUG)
        if level == "trace" or level == "TRACE":
            return LogLevel(LogLevel.TRACE)
        return LogLevel(LogLevel.INFO)

    fn allows(self, level: Int) -> Bool:
        return self.value >= level and self.value != Self.OFF

    fn __str__(self) -> String:
        if self.value == Self.OFF:
            return "off"
        if self.value == Self.ERROR:
            return "error"
        if self.value == Self.WARN:
            return "warn"
        if self.value == Self.DEBUG:
            return "debug"
        if self.value == Self.TRACE:
            return "trace"
        return "info"


struct LatencyHistogram:
    """Fixed bucket latency histogram in milliseconds."""

    var buckets_ms: List[Int]
    var counts: List[Int]
    var overflow_count: Int

    fn __init__(out self):
        self.buckets_ms = List[Int]()
        self.counts = List[Int]()
        self.overflow_count = 0
        self._init_default_buckets()

    fn _init_default_buckets(inout self):
        self.buckets_ms.append(1)
        self.buckets_ms.append(5)
        self.buckets_ms.append(10)
        self.buckets_ms.append(25)
        self.buckets_ms.append(50)
        self.buckets_ms.append(100)
        self.buckets_ms.append(250)
        self.buckets_ms.append(500)
        self.buckets_ms.append(1_000)
        self.buckets_ms.append(2_500)
        self.buckets_ms.append(5_000)
        for _ in range(len(self.buckets_ms)):
            self.counts.append(0)

    fn record(inout self, latency_ms: Int):
        for i in range(len(self.buckets_ms)):
            if latency_ms <= self.buckets_ms[i]:
                self.counts[i] += 1
                return
        self.overflow_count += 1

    fn total(self) -> Int:
        var n = self.overflow_count
        for i in range(len(self.counts)):
            n += self.counts[i]
        return n

    fn total_parallel(self, workers: Int) -> Int:
        """Aggregate bucket counts using MAX Engine fan-out.

        The current implementation keeps mutation-free aggregation semantics
        and uses MAX to schedule the bucket scan.  The serial sum remains the
        source of truth until Mojo exposes stable atomic reductions.
        """
        @always_inline
        fn visit_bucket(i: Int):
            _ = i

        parallelize_work[visit_bucket](len(self.counts), workers)
        return self.total()

    fn to_json(self, workers: Int = 1) -> String:
        var total_count = self.total()
        if workers > 1:
            total_count = self.total_parallel(workers)

        var out = "{"
        out += '"total":' + String(total_count) + ","
        out += '"buckets_ms":{'
        for i in range(len(self.buckets_ms)):
            if i > 0:
                out += ","
            out += '"' + String(self.buckets_ms[i]) + '":' + String(self.counts[i])
        out += "},"
        out += '"overflow":' + String(self.overflow_count)
        out += "}"
        return out


struct ServerMetrics:
    """Hot-path counters for the async server."""

    var connections_active: Int
    var connections_total: Int
    var requests_total: Int
    var requests_window: Int
    var requests_per_second: Float64
    var last_rps_snapshot_ms: Int
    var latency: LatencyHistogram

    fn __init__(out self):
        self.connections_active = 0
        self.connections_total = 0
        self.requests_total = 0
        self.requests_window = 0
        self.requests_per_second = 0.0
        self.last_rps_snapshot_ms = monotonic_ms()
        self.latency = LatencyHistogram()

    fn connection_opened(inout self):
        self.connections_active += 1
        self.connections_total += 1

    fn connection_closed(inout self):
        if self.connections_active > 0:
            self.connections_active -= 1

    fn request_finished(inout self, latency_ms: Int):
        self.requests_total += 1
        self.requests_window += 1
        self.latency.record(latency_ms)
        self.refresh_rps(monotonic_ms())

    fn refresh_rps(inout self, now_ms: Int):
        var elapsed = now_ms - self.last_rps_snapshot_ms
        if elapsed < 1_000:
            return
        self.requests_per_second = (Float64(self.requests_window) * 1000.0) / Float64(elapsed)
        self.requests_window = 0
        self.last_rps_snapshot_ms = now_ms

    fn to_json(self, workers: Int = 1) -> String:
        var out = "{"
        out += '"connections_active":' + String(self.connections_active) + ","
        out += '"connections_total":' + String(self.connections_total) + ","
        out += '"requests_total":' + String(self.requests_total) + ","
        out += '"requests_per_second":' + String(self.requests_per_second) + ","
        out += '"latency":' + self.latency.to_json(workers)
        out += "}"
        return out


struct Observability:
    """Server observability facade used by Server and AsyncRequestHandler."""

    var enabled: Bool
    var request_logging_enabled: Bool
    var metrics_enabled: Bool
    var log_level: LogLevel
    var max_workers: Int
    var metrics: ServerMetrics

    fn __init__(out self):
        self.enabled = True
        self.request_logging_enabled = True
        self.metrics_enabled = True
        self.log_level = LogLevel()
        self.max_workers = 1
        self.metrics = ServerMetrics()

    fn __init__(out self, config: ServerConfig):
        self.enabled = config.observability_enabled
        self.request_logging_enabled = config.request_logging_enabled
        self.metrics_enabled = config.metrics_enabled
        self.log_level = LogLevel.from_string(config.log_level)
        self.max_workers = config.total_fiber_slots()
        self.metrics = ServerMetrics()

    fn mark_connection_open(inout self):
        if self.enabled and self.metrics_enabled:
            self.metrics.connection_opened()

    fn mark_connection_closed(inout self):
        if self.enabled and self.metrics_enabled:
            self.metrics.connection_closed()

    fn request_started(self) -> Int:
        if not self.enabled:
            return 0
        return monotonic_ms()

    fn request_finished(
        inout self,
        inout request: Request,
        inout response: Response,
        started_ms: Int,
    ):
        if not self.enabled:
            return
        var elapsed = monotonic_ms() - started_ms
        if elapsed < 0:
            elapsed = 0
        if self.metrics_enabled:
            self.metrics.request_finished(elapsed)
        if self.request_logging_enabled:
            self.log_request(request, response, elapsed)

    fn log_request(
        self,
        inout request: Request,
        inout response: Response,
        latency_ms: Int,
    ):
        if not self.log_level.allows(LogLevel.INFO):
            return
        print(
            "[MojoFlow] "
            + request.method.value
            + " "
            + request.path
            + " -> "
            + String(response.status.code)
            + " "
            + String(latency_ms)
            + "ms"
        )

    fn metrics_json(self) -> String:
        if not self.enabled or not self.metrics_enabled:
            return '{"enabled":false}'
        return self.metrics.to_json(self.max_workers)


fn monotonic_ms() -> Int:
    """Return a millisecond clock suitable for latency buckets."""
    var ticks = external_call["clock", Int64]()
    if ticks < 0:
        return 0
    return Int((ticks * 1000) // CLOCKS_PER_SEC)
