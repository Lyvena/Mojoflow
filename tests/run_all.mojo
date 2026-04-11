"""
MojoFlow Test Runner — Runs all test suites.

Usage:
    mojo run tests/run_all.mojo
"""


fn main() raises:
    print("=" * 50)
    print("MojoFlow Test Suite")
    print("=" * 50)
    print("")

    # Import and run each test module's main function.
    # In Mojo, we list tests explicitly since dynamic import is limited.
    # Each test file also has its own main() for standalone execution.

    print("[1/6] Core Config tests")
    from tests.test_config import main as test_config_main
    test_config_main()
    print("")

    print("[2/6] Core JSON tests")
    from tests.test_json import main as test_json_main
    test_json_main()
    print("")

    print("[3/6] Server Request tests")
    from tests.test_request import main as test_request_main
    test_request_main()
    print("")

    print("[4/6] Server Response tests")
    from tests.test_response import main as test_response_main
    test_response_main()
    print("")

    print("[5/6] Server Router tests")
    from tests.test_router import main as test_router_main
    test_router_main()
    print("")

    print("[6/6] UI tests")
    from tests.test_ui import main as test_ui_main
    test_ui_main()
    print("")

    print("=" * 50)
    print("All test suites passed!")
    print("=" * 50)
