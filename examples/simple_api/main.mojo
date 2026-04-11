"""
MojoFlow Example — Simple REST API

Demonstrates the backend framework:
- Creating an App with Config (supports .env files)
- Registering routes with different HTTP methods
- Using built-in and custom middleware
- Building JSON responses safely with JsonBuilder
- Route parameters (e.g., /users/:id)

Run: mojo run examples/simple_api/main.mojo
"""

from mojoflow.server.http import App
from mojoflow.core.config import Config
from mojoflow.core.json import JsonBuilder


fn main() raises:
    # Configure the application
    var config = Config(
        app_name="Simple API",
        port=8080,
        debug=True,
        log_level="debug",
    )

    # Create the app
    var app = App(config)

    # Add built-in middleware
    app.use_middleware("logging")
    app.use_middleware("cors")
    app.use_middleware("security")

    # Add custom middleware with response headers
    var custom_headers = List[String]()
    custom_headers.append("X-Powered-By: MojoFlow")
    custom_headers.append("X-API-Version: 0.2.0")
    app.use_custom_middleware("branding", custom_headers)

    # Build JSON responses with JsonBuilder (safe escaping)
    var status_json = JsonBuilder()
    status_json.add_string("status", "ok")
    status_json.add_string("service", "simple-api")
    status_json.add_string("version", "0.2.0")

    var hello_json = JsonBuilder()
    hello_json.add_string("message", "Hello from MojoFlow!")
    hello_json.add_string("framework", "MojoFlow 0.2.0")

    var users_json = JsonBuilder()
    users_json.add_raw(
        "users",
        '[{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]',
    )

    var user_json = JsonBuilder()
    user_json.add_int("id", 1)
    user_json.add_string("name", "Alice")
    user_json.add_string("email", "alice@example.com")

    var created_json = JsonBuilder()
    created_json.add_bool("created", True)
    created_json.add_int("id", 3)
    created_json.add_string("name", "Charlie")

    var deleted_json = JsonBuilder()
    deleted_json.add_bool("deleted", True)

    # Register routes
    app.get("/", status_json.build())
    app.get("/hello", hello_json.build())
    app.get("/users", users_json.build())
    app.get("/users/:id", user_json.build())
    app.post("/users", created_json.build(), status=201)
    app.delete("/users/:id", deleted_json.build())

    # Start the server
    print("Simple API Example")
    print("Available endpoints:")
    print("  GET    /            — Health check")
    print("  GET    /hello       — Greeting")
    print("  GET    /users       — List users")
    print("  GET    /users/:id   — Get user by ID (params extracted)")
    print("  POST   /users       — Create user (201)")
    print("  DELETE /users/:id   — Delete user")
    print("")

    app.listen(8080)
