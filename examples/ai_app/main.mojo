"""
MojoFlow Example — AI-Powered Application

Demonstrates:
- LLM client for AI completions
- Prompt templates with variable interpolation
- Agent-based task execution
- Task orchestration pipeline
- HTTP API serving AI results

Requirements:
    Set OPENAI_API_KEY environment variable before running.

Run:
    export OPENAI_API_KEY="your-key-here"
    mojo run examples/ai_app/main.mojo
"""

from mojoflow.server.http import App
from mojoflow.ai.llm import LLMClient, RetryPolicy
from mojoflow.ai.agent import Agent, AgentConfig
from mojoflow.ai.prompt import PromptTemplate, PromptRegistry
from mojoflow.ai.orchestrator import Task, Pipeline, Orchestrator
from mojoflow.core.config import Config
from mojoflow.core.json import JsonBuilder
from mojoflow.core.types import KeyValue


fn demo_llm_client() raises:
    """Demonstrate basic LLM completion."""
    print("\n=== LLM Client Demo ===\n")

    # LLM client with retry policy for resilience
    var client = LLMClient(
        provider="openai",
        model="gpt-4",
        temperature=0.7,
        max_tokens=256,
        retry_policy=RetryPolicy(max_retries=2, base_delay_seconds=1.0),
    )

    var response = client.complete("Explain what Mojo programming language is in 2 sentences.")
    print("Response: " + response.content)
    print("Tokens used: " + String(response.total_tokens()))


fn demo_prompt_templates() raises:
    """Demonstrate prompt template system."""
    print("\n=== Prompt Template Demo ===\n")

    # Create a registry
    var registry = PromptRegistry()

    # Register templates
    registry.register(
        PromptTemplate(
            name="summarize",
            template="Summarize the following text in {{style}} style:\n\n{{text}}",
            description="Summarize text in a specified style",
        )
    )

    registry.register(
        PromptTemplate(
            name="translate",
            template="Translate the following from {{source_lang}} to {{target_lang}}:\n\n{{text}}",
            description="Translate text between languages",
        )
    )

    # Render a template
    var tpl = registry.get("summarize")
    var vars = List[KeyValue]()
    vars.append(KeyValue("style", "bullet points"))
    vars.append(KeyValue("text", "MojoFlow is an AI-native framework for Mojo..."))

    var prompt = tpl.render(vars)
    print("Rendered prompt:\n" + prompt)

    # Show registered templates
    var names = registry.list_names()
    print("\nRegistered templates: " + String(registry.count()))
    for i in range(len(names)):
        print("  - " + names[i])


fn demo_agent() raises:
    """Demonstrate agent-based task execution."""
    print("\n=== Agent Demo ===\n")

    var client = LLMClient(provider="openai", model="gpt-4")

    var agent_config = AgentConfig(
        max_iterations=3,
        verbose=True,
    )

    var agent = Agent(
        name="code-reviewer",
        llm=client,
        config=agent_config,
    )

    var result = agent.run("Review this Python code and suggest improvements: def add(a,b): return a+b")
    print("\nAgent result:\n" + result)


fn demo_orchestrator() raises:
    """Demonstrate task orchestration pipeline."""
    print("\n=== Orchestrator Demo ===\n")

    var client = LLMClient(provider="openai", model="gpt-4", max_tokens=512)
    var orch = Orchestrator(llm=client, verbose=True)

    var pipeline = Pipeline("content-pipeline")

    # Task 1: Research (no dependencies)
    pipeline.add_task(
        Task("research", "List 3 key benefits of the Mojo programming language. Be concise.")
    )

    # Task 2: Expand (depends on research)
    var deps = List[String]()
    deps.append("research")
    pipeline.add_task(
        Task(
            "expand",
            "Take these points and expand each into a short paragraph:\n\n{{research}}",
            deps,
        )
    )

    # Task 3: Summarize (depends on expand)
    var deps2 = List[String]()
    deps2.append("expand")
    pipeline.add_task(
        Task(
            "summarize",
            "Write a concise executive summary from:\n\n{{expand}}",
            deps2,
        )
    )

    # Execute pipeline
    var results = orch.execute(pipeline)

    print("\n--- Pipeline Results ---")
    for i in range(len(results)):
        print("\nStep " + String(i + 1) + ":")
        print(results[i])


fn main() raises:
    print("=" * 60)
    print("  MojoFlow AI-Powered Application Example")
    print("=" * 60)

    # Demo 1: Prompt templates (no API key needed)
    demo_prompt_templates()

    # Demo 2-4: Require OPENAI_API_KEY
    # Uncomment these when you have an API key set:

    # demo_llm_client()
    # demo_agent()
    # demo_orchestrator()

    # Also start an API server
    print("\n=== Starting API Server ===\n")

    var config = Config(
        app_name="AI App",
        host="127.0.0.1",
        port=8080,
    )
    var app = App(config)
    app.use_middleware("logging")
    app.use_middleware("cors")

    var info_json = JsonBuilder()
    info_json.add_string("name", "AI App")
    info_json.add_string("version", "0.2.0")

    var ask_info_json = JsonBuilder()
    ask_info_json.add_string("info", "Send POST to /ask with a JSON body containing a prompt field")

    var ask_resp_json = JsonBuilder()
    ask_resp_json.add_string("response", "AI response placeholder - connect LLM client for live results")

    app.get("/", info_json.build())
    app.get("/ask", ask_info_json.build())
    app.post("/ask", ask_resp_json.build())

    print("  Endpoints:")
    print("    GET  /     → App info")
    print("    GET  /ask  → Usage info")
    print("    POST /ask  → AI query endpoint")
    print("")

    app.listen(8080)
