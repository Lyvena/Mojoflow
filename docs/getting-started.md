# Getting Started with MojoFlow

## Prerequisites

- [Mojo](https://www.modular.com/mojo) (latest stable release)
- Python 3.10+ (for AI layer interop)

## Installation

```bash
git clone https://github.com/Lyvena/mojoflow.git
cd mojoflow
```

## Your First API

Create a file `main.mojo`:

```mojo
from mojoflow.server import App, Request, Response

fn main() raises:
    var app = App()
    app.get("/hello", hello_handler)
    print("Server running on http://127.0.0.1:8080")
    app.listen(8080)

fn hello_handler(req: Request) raises -> Response:
    return Response.json('{"message": "Hello from MojoFlow!"}')
```

Run it:

```bash
mojo run main.mojo
```

## Adding AI

```mojo
from mojoflow.ai import LLMClient

fn main() raises:
    var client = LLMClient(provider="openai", model="gpt-4")
    var response = client.complete("Explain Mojo in one sentence")
    print(response.content)
```

**Note:** Set the `OPENAI_API_KEY` environment variable before running.

## Project Structure

A typical MojoFlow project:

```
my-app/
├── main.mojo           # Entry point
├── routes/             # Route handlers
├── models/             # Data models
├── mojoproject.toml    # Project config
└── static/             # Static assets
```

## Next Steps

- Read the [Architecture Guide](architecture.md)
- Explore the [examples/](../examples/) directory
- Check the [API Reference](api-reference.md)
