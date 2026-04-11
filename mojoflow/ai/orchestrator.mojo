"""
MojoFlow AI — Task orchestration system.

Provides a pipeline-based orchestration system for chaining
AI tasks with dependency management.
"""

from .llm import LLMClient, LLMResponse


@value
struct Task:
    """A single unit of work in an orchestration pipeline.

    Each task has a name, a prompt, and optional dependencies
    on other tasks (by name). A task only executes after all
    its dependencies have completed.

    Example:
        var t1 = Task("research", "Research the topic: {{topic}}")
        var t2 = Task("summarize", "Summarize: {{research_output}}", depends_on_names)
    """

    var name: String
    var prompt: String
    var depends_on: List[String]
    var result: String
    var completed: Bool

    fn __init__(out self, name: String, prompt: String):
        self.name = name
        self.prompt = prompt
        self.depends_on = List[String]()
        self.result = ""
        self.completed = False

    fn __init__(out self, name: String, prompt: String, depends_on: List[String]):
        self.name = name
        self.prompt = prompt
        self.depends_on = depends_on
        self.result = ""
        self.completed = False


@value
struct Pipeline:
    """An ordered collection of tasks forming a workflow.

    Tasks are stored in order and can reference each other
    by name for dependency resolution.
    """

    var name: String
    var tasks: List[Task]

    fn __init__(out self, name: String):
        self.name = name
        self.tasks = List[Task]()

    fn add_task(inout self, task: Task):
        self.tasks.append(task)

    fn task_count(self) -> Int:
        return len(self.tasks)

    fn get_task(self, name: String) -> Task:
        """Find a task by name. Returns empty task if not found."""
        for i in range(len(self.tasks)):
            if self.tasks[i].name == name:
                return self.tasks[i]
        return Task("", "")


struct Orchestrator:
    """Executes task pipelines with dependency resolution.

    The orchestrator processes tasks in topological order,
    substituting previous task outputs into subsequent prompts.

    Output placeholders use {{task_name}} syntax to reference
    the result of a previously completed task.

    Example:
        var orch = Orchestrator(llm=client)
        var pipeline = Pipeline("analysis")

        var t1 = Task("extract", "Extract key points from: ...")
        var deps = List[String]()
        deps.append("extract")
        var t2 = Task("summarize", "Summarize these points: {{extract}}", deps)

        pipeline.add_task(t1)
        pipeline.add_task(t2)

        var results = orch.execute(pipeline)
    """

    var llm: LLMClient
    var verbose: Bool

    fn __init__(out self, llm: LLMClient, verbose: Bool = False):
        self.llm = llm
        self.verbose = verbose

    fn execute(self, inout pipeline: Pipeline) raises -> List[String]:
        """Execute all tasks in the pipeline in dependency order.

        Returns a list of results, one per task, in pipeline order.
        """
        var results = List[String]()
        var completed_names = List[String]()
        var completed_results = List[String]()

        if self.verbose:
            print(
                "[Orchestrator] Starting pipeline: "
                + pipeline.name
                + " ("
                + String(pipeline.task_count())
                + " tasks)"
            )

        # Process tasks in order (assumes topological ordering)
        for i in range(len(pipeline.tasks)):
            var task = pipeline.tasks[i]

            if self.verbose:
                print("[Orchestrator] Running task: " + task.name)

            # Check dependencies
            for d in range(len(task.depends_on)):
                var dep_name = task.depends_on[d]
                var dep_found = False
                for c in range(len(completed_names)):
                    if completed_names[c] == dep_name:
                        dep_found = True
                        break
                if not dep_found:
                    raise Error(
                        "Task '"
                        + task.name
                        + "' depends on '"
                        + dep_name
                        + "' which has not completed"
                    )

            # Substitute outputs from completed tasks into the prompt
            var prompt = task.prompt
            for c in range(len(completed_names)):
                var placeholder = "{{" + completed_names[c] + "}}"
                while placeholder in prompt:
                    var idx = prompt.find(placeholder)
                    if idx == -1:
                        break
                    prompt = (
                        prompt[:idx]
                        + completed_results[c]
                        + prompt[idx + len(placeholder) :]
                    )

            # Execute LLM call
            var response = self.llm.complete(prompt)
            var result = response.content

            # Store result
            pipeline.tasks[i].result = result
            pipeline.tasks[i].completed = True
            completed_names.append(task.name)
            completed_results.append(result)
            results.append(result)

            if self.verbose:
                print("[Orchestrator] Task '" + task.name + "' completed")

        if self.verbose:
            print("[Orchestrator] Pipeline '" + pipeline.name + "' finished")

        return results

    fn execute_single(self, task: Task) raises -> String:
        """Execute a single task without dependencies."""
        var response = self.llm.complete(task.prompt)
        return response.content
