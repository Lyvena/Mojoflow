"""
MojoFlow Core Config — Application configuration management.

Supports programmatic configuration, .env file loading, and
environment variable overrides.
"""

from python import Python, PythonObject


@value
struct Config:
    """Application configuration with sensible defaults.

    Configuration priority (highest wins):
    1. Programmatic values passed to __init__
    2. Environment variables (MOJOFLOW_PORT, MOJOFLOW_HOST, etc.)
    3. .env file values
    4. Built-in defaults
    """

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

    @staticmethod
    fn from_env() raises -> Config:
        """Create a Config by reading from environment variables and .env file.

        Loads .env file first (if present), then reads MOJOFLOW_* env vars.
        """
        var config = Config()

        # Load .env file if it exists
        Config._load_dotenv()

        var os = Python.import_module("os")
        var env_get = os.environ.get

        var app_name = String(str(env_get("MOJOFLOW_APP_NAME", "")))
        if app_name != "":
            config.app_name = app_name

        var host = String(str(env_get("MOJOFLOW_HOST", "")))
        if host != "":
            config.host = host

        var port_str = String(str(env_get("MOJOFLOW_PORT", "")))
        if port_str != "":
            try:
                config.port = Int(port_str)
            except:
                pass

        var debug_str = String(str(env_get("MOJOFLOW_DEBUG", "")))
        if debug_str == "true" or debug_str == "1":
            config.debug = True

        var log_level = String(str(env_get("MOJOFLOW_LOG_LEVEL", "")))
        if log_level != "":
            config.log_level = log_level

        var ai_provider = String(str(env_get("MOJOFLOW_AI_PROVIDER", "")))
        if ai_provider != "":
            config.ai_provider = ai_provider

        var ai_model = String(str(env_get("MOJOFLOW_AI_MODEL", "")))
        if ai_model != "":
            config.ai_model = ai_model

        var ai_key = String(str(env_get("OPENAI_API_KEY", "")))
        if ai_key == "":
            ai_key = String(str(env_get("ANTHROPIC_API_KEY", "")))
        if ai_key != "":
            config.ai_api_key = ai_key

        return config

    @staticmethod
    fn _load_dotenv() raises:
        """Load key=value pairs from a .env file into environment variables.

        Supports:
        - KEY=value
        - KEY="quoted value"
        - # comments
        - Empty lines
        """
        var os = Python.import_module("os")
        if not os.path.exists(".env"):
            return

        var builtins = Python.import_module("builtins")
        var f = builtins.open(".env", "r")
        var lines = f.readlines()
        f.close()

        for i in range(Int(len(lines))):
            var line = String(str(lines[i])).strip()

            # Skip empty lines and comments
            if len(line) == 0:
                continue
            if line[0] == "#":
                continue

            var eq_idx = line.find("=")
            if eq_idx == -1:
                continue

            var key = line[:eq_idx].strip()
            var value = line[eq_idx + 1 :].strip()

            # Strip surrounding quotes
            if len(value) >= 2:
                if (value[0] == '"' and value[len(value) - 1] == '"') or (
                    value[0] == "'" and value[len(value) - 1] == "'"
                ):
                    value = value[1 : len(value) - 1]

            os.environ.__setitem__(key, value)
