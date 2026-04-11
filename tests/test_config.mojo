"""
Tests for MojoFlow Core Config.
"""

from mojoflow.core.config import Config


fn test_default_config() raises:
    """Test default configuration values."""
    var config = Config()
    if config.app_name != "MojoFlow App":
        raise Error("Default app_name wrong: " + config.app_name)
    if config.host != "127.0.0.1":
        raise Error("Default host wrong: " + config.host)
    if config.port != 8080:
        raise Error("Default port wrong: " + String(config.port))
    if config.debug:
        raise Error("Debug should default to False")
    if config.log_level != "info":
        raise Error("Default log_level wrong: " + config.log_level)
    print("  ✓ test_default_config")


fn test_custom_config() raises:
    """Test custom configuration values."""
    var config = Config(
        app_name="TestApp",
        host="0.0.0.0",
        port=3000,
        debug=True,
        log_level="debug",
    )
    if config.app_name != "TestApp":
        raise Error("app_name wrong")
    if config.host != "0.0.0.0":
        raise Error("host wrong")
    if config.port != 3000:
        raise Error("port wrong")
    if not config.debug:
        raise Error("debug should be True")
    print("  ✓ test_custom_config")


fn test_address() raises:
    """Test address formatting."""
    var config = Config(host="localhost", port=9090)
    if config.address() != "localhost:9090":
        raise Error("Address wrong: " + config.address())
    print("  ✓ test_address")


fn test_is_debug() raises:
    """Test is_debug helper."""
    var c1 = Config(debug=True)
    var c2 = Config(debug=False)
    if not c1.is_debug():
        raise Error("Should be debug")
    if c2.is_debug():
        raise Error("Should not be debug")
    print("  ✓ test_is_debug")


fn main() raises:
    print("Running Config tests...")
    test_default_config()
    test_custom_config()
    test_address()
    test_is_debug()
    print("All Config tests passed!")
