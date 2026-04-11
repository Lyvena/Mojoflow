"""
MojoFlow Server — Structured logging.
"""

from time import now


@value
struct LogLevel:
    """Log level constants."""

    alias DEBUG = 0
    alias INFO = 1
    alias WARN = 2
    alias ERROR = 3
    alias FATAL = 4

    var level: Int

    fn __init__(out self, level: Int = 1):
        self.level = level

    @staticmethod
    fn from_string(name: String) -> LogLevel:
        if name == "debug":
            return LogLevel(LogLevel.DEBUG)
        elif name == "warn" or name == "warning":
            return LogLevel(LogLevel.WARN)
        elif name == "error":
            return LogLevel(LogLevel.ERROR)
        elif name == "fatal":
            return LogLevel(LogLevel.FATAL)
        else:
            return LogLevel(LogLevel.INFO)

    fn name(self) -> String:
        if self.level == LogLevel.DEBUG:
            return "DEBUG"
        elif self.level == LogLevel.INFO:
            return "INFO"
        elif self.level == LogLevel.WARN:
            return "WARN"
        elif self.level == LogLevel.ERROR:
            return "ERROR"
        elif self.level == LogLevel.FATAL:
            return "FATAL"
        return "UNKNOWN"


struct Logger:
    """Structured logger for MojoFlow applications.

    Supports log levels and prefixed output.
    """

    var prefix: String
    var min_level: LogLevel

    fn __init__(out self, prefix: String = "MojoFlow", level: String = "info"):
        self.prefix = prefix
        self.min_level = LogLevel.from_string(level)

    fn _should_log(self, level: LogLevel) -> Bool:
        return level.level >= self.min_level.level

    fn _format(self, level: LogLevel, message: String) -> String:
        return "[" + self.prefix + "] [" + level.name() + "] " + message

    fn debug(self, message: String):
        var level = LogLevel(LogLevel.DEBUG)
        if self._should_log(level):
            print(self._format(level, message))

    fn info(self, message: String):
        var level = LogLevel(LogLevel.INFO)
        if self._should_log(level):
            print(self._format(level, message))

    fn warn(self, message: String):
        var level = LogLevel(LogLevel.WARN)
        if self._should_log(level):
            print(self._format(level, message))

    fn error(self, message: String):
        var level = LogLevel(LogLevel.ERROR)
        if self._should_log(level):
            print(self._format(level, message))

    fn fatal(self, message: String):
        var level = LogLevel(LogLevel.FATAL)
        if self._should_log(level):
            print(self._format(level, message))

    fn request(self, method: String, path: String, status: Int):
        """Log an HTTP request with method, path, and response status."""
        var msg = method + " " + path + " -> " + String(status)
        self.info(msg)
