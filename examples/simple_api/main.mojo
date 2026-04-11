"""
MojoFlow Example — Simple REST API

Demonstrates:
- Creating an App with custom config
- Registering GET and POST routes
- Middleware (logging + CORS)
- JSON responses

Run:
    mojo run examples/simple_api/main.mojo

Then visit:
    http://127.0.0.1:8080/
    http://127.0.0.1:8080/hello
    http://127.0.0.1:8080/health
    http://127.0.0.1:8080/users
"""

from mojoflow.server import App
from mojoflow.core import Config


fn main() raises:
    # Configure the application
    var config = Config(
        app_name="SimpleAPI",
        host="127.0.0.1",
        port=8080,
        debug=True,
        log_level="debug",
    )

    # Create the app
    var app = App(config)

    # Add middleware
    app.use_middleware("logging")
    app.use_middleware("cors")

    # Register routes
    app.get("/", '{"name": "SimpleAPI", "version": "0.1.0", "status": "running"}')

    app.get(
        "/hello",
        '{"message": "Hello from MojoFlow!", "framework": "MojoFlow v0.1.0"}',
    )

    app.get("/health", '{"status": "healthy", "uptime": "ok"}')

    app.get(
        "/users",
        '{"users": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}',
    )

    app.post(
        "/users",
        '{"created": true, "message": "User created successfully"}',
    )

    app.get(
        "/users/:id",
        '{"id": 1, "name": "Alice", "email": "alice@example.com"}',
    )

    # Start listening
    print("")
    print("  Simple API Example")
    print("  ==================")
    print("  Endpoints:")
    print("    GET  /        → App info")
    print("    GET  /hello   → Hello message")
    print("    GET  /health  → Health check")
    print("    GET  /users   → List users")
    print("    POST /users   → Create user")
    print("    GET  /users/:id → Get user by ID")
    print("")

    app.listen(8080)
