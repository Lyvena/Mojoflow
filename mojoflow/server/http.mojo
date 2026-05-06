"""
MojoFlow Server — compatibility App API.

The AI and UI examples historically import `App` from
`mojoflow.server.http`.  This wrapper keeps that API while delegating to the
new async `Server` implementation.
"""

from ..core.config import Config
from .config import ServerConfig
from .types import Request, Response
from .server import (
    Server,
    Router,
    RouteDecorator,
    FunctionRouteAdapter,
    AsyncFunctionRouteAdapter,
)
from .handler import HandlerContext


struct App:
    """Compatibility wrapper over the async Server."""

    var config: Config
    var server: Server

    fn __init__(out self):
        self.config = Config()
        self.server = Server(Self._server_config(self.config))

    fn __init__(out self, config: Config):
        self.config = config
        self.server = Server(Self._server_config(config))

    @staticmethod
    fn _server_config(config: Config) -> ServerConfig:
        return ServerConfig(
            host=config.host,
            port=config.port,
            worker_fibers=config.workers,
            debug=config.debug,
            log_level=config.log_level,
            server_name=config.app_name,
        )

    fn get(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        self.server.get(path, body, status)

    fn get(inout self, path: String) -> RouteDecorator:
        return self.server.get(path)

    fn post(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        self.server.post(path, body, status)

    fn post(inout self, path: String) -> RouteDecorator:
        return self.server.post(path)

    fn put(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        self.server.put(path, body, status)

    fn delete(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        self.server.delete(path, body, status)

    fn patch(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        self.server.patch(path, body, status)

    fn decorate_get[
        handler_fn: fn (Request) raises -> Response
    ](inout self, path: String) -> FunctionRouteAdapter[handler_fn]:
        return self.server.decorate_get[handler_fn](path)

    fn decorate_post[
        handler_fn: fn (Request) raises -> Response
    ](inout self, path: String) -> FunctionRouteAdapter[handler_fn]:
        return self.server.decorate_post[handler_fn](path)

    fn decorate_get_async[
        handler_fn: fn (Request, HandlerContext) raises -> Response
    ](inout self, path: String) -> AsyncFunctionRouteAdapter[handler_fn]:
        return self.server.decorate_get_async[handler_fn](path)

    fn decorate_post_async[
        handler_fn: fn (Request, HandlerContext) raises -> Response
    ](inout self, path: String) -> AsyncFunctionRouteAdapter[handler_fn]:
        return self.server.decorate_post_async[handler_fn](path)

    fn use_router(inout self, router: Router):
        self.server.use_router(router)

    fn use_middleware(inout self, name: String):
        """Compatibility hook for existing examples.

        Named middleware registration is preserved as a no-op until the typed
        async middleware stack grows heterogeneous storage.
        """
        pass

    fn use_custom_middleware(inout self, name: String, headers: List[String]):
        """Compatibility hook for existing examples."""
        pass

    fn listen(inout self, port: Int) raises:
        self.server.config.port = port
        self.server.listen_and_serve()

    fn listen_and_serve(inout self) raises:
        self.server.listen_and_serve()

    fn shutdown(inout self):
        self.server.shutdown()
