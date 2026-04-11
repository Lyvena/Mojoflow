"""
MojoFlow AI — Agent execution system.

Provides autonomous agents that can execute tasks using LLMs
with an iterative reasoning loop.
"""

from .llm import LLMClient, LLMResponse
from .prompt import PromptTemplate
from ..core.types import KeyValue


@value
struct AgentConfig:
    """Configuration for an Agent."""

    var max_iterations: Int
    var verbose: Bool
    var stop_on_error: Bool
    var temperature: Float64

    fn __init__(
        out self,
        max_iterations: Int = 10,
        verbose: Bool = False,
        stop_on_error: Bool = True,
        temperature: Float64 = 0.7,
    ):
        self.max_iterations = max_iterations
        self.verbose = verbose
        self.stop_on_error = stop_on_error
        self.temperature = temperature


struct Agent:
    """An AI agent that executes tasks using an LLM with an iterative loop.

    The agent follows a think → act → observe cycle:
    1. Receives a task description
    2. Sends it to the LLM with context
    3. Processes the response
    4. Optionally continues iterating based on output

    Example:
        var client = LLMClient(provider="openai", model="gpt-4")
        var agent = Agent(name="researcher", llm=client)
        var result = agent.run("Analyze the pros and cons of Mojo")
        print(result)
    """

    var name: String
    var llm: LLMClient
    var config: AgentConfig
    var system_prompt: String
    var history: List[String]

    fn __init__(
        out self,
        name: String,
        llm: LLMClient,
        config: AgentConfig = AgentConfig(),
        system_prompt: String = "",
    ):
        self.name = name
        self.llm = llm
        self.config = config
        self.history = List[String]()

        if system_prompt == "":
            self.system_prompt = (
                "You are an AI agent named '"
                + name
                + "'. Complete the given task thoroughly and concisely. "
                + "If the task is complete, respond with your final answer. "
                + "If you need more steps, prefix your response with 'CONTINUE:' "
                + "followed by your reasoning."
            )
        else:
            self.system_prompt = system_prompt

    fn run(inout self, task: String) raises -> String:
        """Execute a task and return the final result.

        Runs the agent loop up to max_iterations times.
        """
        if self.config.verbose:
            print("[Agent:" + self.name + "] Starting task: " + task)

        var current_prompt = task
        var iteration = 0
        var final_result: String = ""

        while iteration < self.config.max_iterations:
            iteration += 1

            if self.config.verbose:
                print(
                    "[Agent:"
                    + self.name
                    + "] Iteration "
                    + String(iteration)
                )

            var response = self.llm.complete_with_system(
                current_prompt, self.system_prompt
            )

            var content = response.content
            self.history.append(content)

            # Check if agent wants to continue (safe length check first)
            var trimmed = content.strip()
            var wants_continue = False
            if len(trimmed) >= 9:
                var prefix = trimmed[:9].upper()
                if prefix == "CONTINUE:":
                    wants_continue = True

            if wants_continue:
                # Agent wants another iteration
                var reasoning = trimmed[9:].strip()
                current_prompt = (
                    "Previous reasoning: "
                    + reasoning
                    + "\n\nOriginal task: "
                    + task
                    + "\n\nContinue working on this task."
                )
                if self.config.verbose:
                    print("[Agent:" + self.name + "] Continuing...")
            else:
                # Agent is done
                final_result = content
                break

        if final_result == "":
            final_result = self.history[len(self.history) - 1]

        if self.config.verbose:
            print(
                "[Agent:"
                + self.name
                + "] Completed in "
                + String(iteration)
                + " iterations"
            )

        return final_result

    fn run_with_context(inout self, task: String, context: String) raises -> String:
        """Execute a task with additional context."""
        var full_prompt = "Context:\n" + context + "\n\nTask:\n" + task
        return self.run(full_prompt)

    fn clear_history(inout self):
        """Clear the agent's conversation history."""
        self.history = List[String]()

    fn get_history(self) -> List[String]:
        """Get the agent's conversation history."""
        return self.history

    fn iteration_count(self) -> Int:
        """Number of iterations in the last run."""
        return len(self.history)
