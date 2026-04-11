"""
MojoFlow CLI — Main entry point and argument parser.

Usage:
    mojoflow create <name> [--template=api|ai]
    mojoflow dev [--port=8080]
    mojoflow build [--output=build]
    mojoflow deploy [--target=local]
"""

from python import Python, PythonObject
from .commands import (
    CLICommand,
    CreateCommand,
    DevCommand,
    BuildCommand,
    DeployCommand,
)


struct CLI:
    """MojoFlow command-line interface.

    Parses arguments and dispatches to the appropriate command handler.
    """

    var version: String
    var commands: List[CLICommand]

    fn __init__(out self):
        self.version = "0.1.0"
        self.commands = List[CLICommand]()
        self.commands.append(
            CLICommand("create", "Create a new MojoFlow project", "mojoflow create <name>")
        )
        self.commands.append(
            CLICommand("dev", "Start development server", "mojoflow dev [--port=8080]")
        )
        self.commands.append(
            CLICommand("build", "Build for production", "mojoflow build [--output=build]")
        )
        self.commands.append(
            CLICommand("deploy", "Deploy application", "mojoflow deploy [--target=local]")
        )

    fn run(self) raises:
        """Parse command-line arguments and execute the matching command."""
        var sys = Python.import_module("sys")
        var args = sys.argv

        var argc = Int(len(args))

        if argc < 2:
            self._print_help()
            return

        var command = String(str(args[1]))

        if command == "create":
            if argc < 3:
                print("Error: Project name required.")
                print("Usage: mojoflow create <name> [--template=api|ai]")
                return
            var name = String(str(args[2]))
            var template = String("api")
            # Check for --template flag
            for i in range(3, argc):
                var arg = String(str(args[i]))
                if arg[:11] == "--template=":
                    template = arg[11:]
            var cmd = CreateCommand(name, template)
            cmd.execute()

        elif command == "dev":
            var port = 8080
            for i in range(2, argc):
                var arg = String(str(args[i]))
                if arg[:7] == "--port=":
                    try:
                        port = Int(arg[7:])
                    except:
                        print("Warning: Invalid port, using default 8080")
            var cmd = DevCommand(port)
            cmd.execute()

        elif command == "build":
            var output = String("build")
            for i in range(2, argc):
                var arg = String(str(args[i]))
                if arg[:9] == "--output=":
                    output = arg[9:]
            var cmd = BuildCommand(output)
            cmd.execute()

        elif command == "deploy":
            var target = String("local")
            for i in range(2, argc):
                var arg = String(str(args[i]))
                if arg[:9] == "--target=":
                    target = arg[9:]
            var cmd = DeployCommand(target)
            cmd.execute()

        elif command == "--help" or command == "-h":
            self._print_help()

        elif command == "--version" or command == "-v":
            print("MojoFlow v" + self.version)

        else:
            print("Unknown command: " + command)
            self._print_help()

    fn _print_help(self):
        """Print CLI help text."""
        print("")
        print("  MojoFlow v" + self.version + " — AI-Native Full-Stack Framework for Mojo")
        print("")
        print("  USAGE:")
        print("    mojoflow <command> [options]")
        print("")
        print("  COMMANDS:")
        for i in range(len(self.commands)):
            var cmd = self.commands[i]
            var padding = "          "
            if len(cmd.name) >= 8:
                padding = "  "
            elif len(cmd.name) >= 6:
                padding = "    "
            print("    " + cmd.name + padding + cmd.description)
        print("")
        print("  OPTIONS:")
        print("    --help, -h       Show this help message")
        print("    --version, -v    Show version")
        print("")
