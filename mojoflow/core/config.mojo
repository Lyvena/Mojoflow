"""
MojoFlow Core Config — Application configuration management.
"""


@value
struct Config:
    """Application configuration with sensible defaults."""

    var app_name: String
    var host: String
    var port: Int
    var debug: Bool
    var log_level: String
    var workers: Int
    var ai_provider: String
    var ai_model: String
    var ai_api_key: String

    fn __init__(out self):
        """Initialize with default configuration."""
        self.app_name = "MojoFlow App"
        self.host = "127.0.0.1"
        self.port = 8080
        self.debug = False
        self.log_level = "info"
        self.workers = 1
        self.ai_provider = ""
        self.ai_model = ""
        self.ai_api_key = ""

    fn __init__(
        out self,
        app_name: String = "MojoFlow App",
        host: String = "127.0.0.1",
        port: Int = 8080,
        debug: Bool = False,
        log_level: String = "info",
        workers: Int = 1,
        ai_provider: String = "",
        ai_model: String = "",
        ai_api_key: String = "",
    ):
        self.app_name = app_name
        self.host = host
        self.port = port
        self.debug = debug
        self.log_level = log_level
        self.workers = workers
        self.ai_provider = ai_provider
        self.ai_model = ai_model
        self.ai_api_key = ai_api_key

    fn is_debug(self) -> Bool:
        return self.debug

    fn address(self) -> String:
        return self.host + ":" + String(self.port)
