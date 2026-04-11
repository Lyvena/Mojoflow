"""
MojoFlow AI — LLM Client abstraction.

Provider-agnostic interface for calling Large Language Models.
Supports OpenAI, Anthropic, and local models via a unified API.

Features:
- Unified complete() interface across providers
- Automatic API key discovery from environment
- Configurable retry with exponential backoff
- Structured error handling for API failures

Uses Python interop for HTTP calls in the MVP.
"""

from python import Python, PythonObject


@value
struct LLMResponse:
    """Response from an LLM API call."""

    var content: String
    var model: String
    var provider: String
    var prompt_tokens: Int
    var completion_tokens: Int
    var finish_reason: String

    fn __init__(out self):
        self.content = ""
        self.model = ""
        self.provider = ""
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.finish_reason = ""

    fn __init__(
        out self,
        content: String,
        model: String = "",
        provider: String = "",
        prompt_tokens: Int = 0,
        completion_tokens: Int = 0,
        finish_reason: String = "stop",
    ):
        self.content = content
        self.model = model
        self.provider = provider
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.finish_reason = finish_reason

    fn total_tokens(self) -> Int:
        return self.prompt_tokens + self.completion_tokens

    fn is_error(self) -> Bool:
        """Check if this response represents an error."""
        return self.finish_reason == "error"

    fn __str__(self) -> String:
        return self.content


@value
struct RetryPolicy:
    """Configuration for automatic retries on transient failures.

    Uses exponential backoff: delay * (2 ^ attempt).
    """

    var max_retries: Int
    var base_delay_seconds: Float64
    var retry_on_rate_limit: Bool

    fn __init__(
        out self,
        max_retries: Int = 2,
        base_delay_seconds: Float64 = 1.0,
        retry_on_rate_limit: Bool = True,
    ):
        self.max_retries = max_retries
        self.base_delay_seconds = base_delay_seconds
        self.retry_on_rate_limit = retry_on_rate_limit


struct LLMClient:
    """Provider-agnostic LLM client with retry support.

    Supports:
    - "openai"    → OpenAI Chat Completions API
    - "anthropic" → Anthropic Messages API
    - "local"     → Local model endpoint (OpenAI-compatible)

    Example:
        var client = LLMClient(provider="openai", model="gpt-4")
        var resp = client.complete("Hello, world!")
        print(resp.content)
    """

    var provider: String
    var model: String
    var api_key: String
    var base_url: String
    var temperature: Float64
    var max_tokens: Int
    var system_prompt: String
    var retry_policy: RetryPolicy

    fn __init__(
        out self,
        provider: String = "openai",
        model: String = "gpt-4",
        api_key: String = "",
        base_url: String = "",
        temperature: Float64 = 0.7,
        max_tokens: Int = 2048,
        system_prompt: String = "You are a helpful assistant.",
        retry_policy: RetryPolicy = RetryPolicy(),
    ):
        self.provider = provider
        self.model = model
        self.api_key = api_key
        self.base_url = base_url
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.system_prompt = system_prompt
        self.retry_policy = retry_policy

    fn complete(self, prompt: String) raises -> LLMResponse:
        """Send a completion request using the default system prompt."""
        return self.complete_with_system(prompt, self.system_prompt)

    fn complete_with_system(self, prompt: String, system: String) raises -> LLMResponse:
        """Send a completion with a custom system prompt.

        Automatically resolves the API key and dispatches to the correct
        provider with retry logic on transient failures.
        """
        var key = self.api_key
        if key == "":
            key = self._get_env_key()
        if key == "":
            raise Error(
                "No API key found for provider '"
                + self.provider
                + "'. Set it via api_key parameter or environment variable."
            )

        if self.provider == "openai" or self.provider == "local":
            return self._call_with_retry(prompt, system, key, "openai")
        elif self.provider == "anthropic":
            return self._call_with_retry(prompt, system, key, "anthropic")
        else:
            raise Error("Unsupported LLM provider: " + self.provider)

    fn _get_env_key(self) raises -> String:
        """Read API key from environment variables."""
        var os = Python.import_module("os")
        if self.provider == "openai" or self.provider == "local":
            return String(str(os.environ.get("OPENAI_API_KEY", "")))
        elif self.provider == "anthropic":
            return String(str(os.environ.get("ANTHROPIC_API_KEY", "")))
        return ""

    fn _call_with_retry(
        self,
        prompt: String,
        system: String,
        api_key: String,
        provider_type: String,
    ) raises -> LLMResponse:
        """Execute an API call with exponential-backoff retry on failures."""
        var time_mod = Python.import_module("time")
        var last_error = String("")

        for attempt in range(self.retry_policy.max_retries + 1):
            try:
                if provider_type == "openai":
                    return self._call_openai(prompt, system, api_key)
                else:
                    return self._call_anthropic(prompt, system, api_key)
            except e:
                last_error = String(e)
                var is_rate_limit = "429" in last_error or "rate" in last_error.lower()
                var is_server_error = "500" in last_error or "502" in last_error or "503" in last_error

                # Only retry on transient errors
                if not is_rate_limit and not is_server_error:
                    raise Error("LLM API error (" + self.provider + "): " + last_error)

                if is_rate_limit and not self.retry_policy.retry_on_rate_limit:
                    raise Error("Rate limited by " + self.provider + ": " + last_error)

                if attempt < self.retry_policy.max_retries:
                    var delay = self.retry_policy.base_delay_seconds * Float64(
                        1 << attempt
                    )
                    time_mod.sleep(delay)

        raise Error(
            "LLM API failed after "
            + String(self.retry_policy.max_retries + 1)
            + " attempts ("
            + self.provider
            + "): "
            + last_error
        )

    fn _call_openai(
        self, prompt: String, system: String, api_key: String
    ) raises -> LLMResponse:
        """Call an OpenAI-compatible chat completions API."""
        var json_mod = Python.import_module("json")
        var urllib_request = Python.import_module("urllib.request")
        var urllib_error = Python.import_module("urllib.error")

        var url = self.base_url
        if url == "":
            url = "https://api.openai.com/v1/chat/completions"

        var payload = json_mod.dumps(
            {
                "model": self.model,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": prompt},
                ],
                "temperature": self.temperature,
                "max_tokens": self.max_tokens,
            }
        )

        var req = urllib_request.Request(url)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", "Bearer " + api_key)
        req.data = String(str(payload)).encode()

        try:
            var response = urllib_request.urlopen(req, timeout=60)
            var body = response.read().decode("utf-8")
            var data = json_mod.loads(body)

            var content = String(str(data["choices"][0]["message"]["content"]))
            var usage = data.get("usage", {})
            var pt = Int(usage.get("prompt_tokens", 0))
            var ct = Int(usage.get("completion_tokens", 0))
            var fr = String(str(data["choices"][0].get("finish_reason", "stop")))

            return LLMResponse(content, self.model, self.provider, pt, ct, fr)
        except e:
            var err_str = String(e)
            # Try to parse error body for better messages
            if "HTTP Error" in err_str:
                raise Error("OpenAI API error: " + err_str)
            raise Error("OpenAI request failed: " + err_str)

    fn _call_anthropic(
        self, prompt: String, system: String, api_key: String
    ) raises -> LLMResponse:
        """Call the Anthropic Messages API."""
        var json_mod = Python.import_module("json")
        var urllib_request = Python.import_module("urllib.request")

        var url = "https://api.anthropic.com/v1/messages"

        var payload = json_mod.dumps(
            {
                "model": self.model,
                "max_tokens": self.max_tokens,
                "system": system,
                "messages": [{"role": "user", "content": prompt}],
            }
        )

        var req = urllib_request.Request(url)
        req.add_header("Content-Type", "application/json")
        req.add_header("x-api-key", api_key)
        req.add_header("anthropic-version", "2023-06-01")
        req.data = String(str(payload)).encode()

        try:
            var response = urllib_request.urlopen(req, timeout=60)
            var body = response.read().decode("utf-8")
            var data = json_mod.loads(body)

            var content = String(str(data["content"][0]["text"]))
            var usage = data.get("usage", {})
            var pt = Int(usage.get("input_tokens", 0))
            var ct = Int(usage.get("output_tokens", 0))
            var stop = String(str(data.get("stop_reason", "end_turn")))

            return LLMResponse(content, self.model, self.provider, pt, ct, stop)
        except e:
            var err_str = String(e)
            if "HTTP Error" in err_str:
                raise Error("Anthropic API error: " + err_str)
            raise Error("Anthropic request failed: " + err_str)
