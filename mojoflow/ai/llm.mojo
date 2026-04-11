"""
MojoFlow AI — LLM Client abstraction.

Provider-agnostic interface for calling Large Language Models.
Supports OpenAI, Anthropic, and local models via a unified API.

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

    fn __str__(self) -> String:
        return self.content


struct LLMClient:
    """Provider-agnostic LLM client.

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

    fn __init__(
        out self,
        provider: String = "openai",
        model: String = "gpt-4",
        api_key: String = "",
        base_url: String = "",
        temperature: Float64 = 0.7,
        max_tokens: Int = 2048,
        system_prompt: String = "You are a helpful assistant.",
    ):
        self.provider = provider
        self.model = model
        self.api_key = api_key
        self.base_url = base_url
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.system_prompt = system_prompt

    fn complete(self, prompt: String) raises -> LLMResponse:
        """Send a completion request to the configured LLM provider.

        If api_key is empty, attempts to read from environment:
        - OPENAI_API_KEY for openai provider
        - ANTHROPIC_API_KEY for anthropic provider
        """
        var key = self.api_key
        if key == "":
            key = self._get_env_key()

        if self.provider == "openai" or self.provider == "local":
            return self._call_openai_compatible(prompt, key)
        elif self.provider == "anthropic":
            return self._call_anthropic(prompt, key)
        else:
            raise Error("Unsupported LLM provider: " + self.provider)

    fn complete_with_system(self, prompt: String, system: String) raises -> LLMResponse:
        """Send a completion with a custom system prompt."""
        var key = self.api_key
        if key == "":
            key = self._get_env_key()

        if self.provider == "openai" or self.provider == "local":
            return self._call_openai_with_system(prompt, system, key)
        elif self.provider == "anthropic":
            return self._call_anthropic_with_system(prompt, system, key)
        else:
            raise Error("Unsupported LLM provider: " + self.provider)

    fn _get_env_key(self) raises -> String:
        """Read API key from environment variables."""
        var os = Python.import_module("os")
        if self.provider == "openai" or self.provider == "local":
            var key = os.environ.get("OPENAI_API_KEY", "")
            return String(str(key))
        elif self.provider == "anthropic":
            var key = os.environ.get("ANTHROPIC_API_KEY", "")
            return String(str(key))
        return ""

    fn _call_openai_compatible(self, prompt: String, api_key: String) raises -> LLMResponse:
        """Call an OpenAI-compatible chat completions API."""
        var json_mod = Python.import_module("json")
        var urllib = Python.import_module("urllib.request")

        var url = self.base_url
        if url == "":
            url = "https://api.openai.com/v1/chat/completions"

        var payload = json_mod.dumps(
            {
                "model": self.model,
                "messages": [
                    {"role": "system", "content": self.system_prompt},
                    {"role": "user", "content": prompt},
                ],
                "temperature": self.temperature,
                "max_tokens": self.max_tokens,
            }
        )

        var req = urllib.Request(url)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", "Bearer " + api_key)
        req.data = String(str(payload)).encode()

        var response = urllib.urlopen(req)
        var body = response.read().decode("utf-8")
        var data = json_mod.loads(body)

        var content = String(str(data["choices"][0]["message"]["content"]))
        var usage = data.get("usage", {})
        var pt = Int(usage.get("prompt_tokens", 0))
        var ct = Int(usage.get("completion_tokens", 0))
        var fr = String(str(data["choices"][0].get("finish_reason", "stop")))

        return LLMResponse(content, self.model, self.provider, pt, ct, fr)

    fn _call_openai_with_system(
        self, prompt: String, system: String, api_key: String
    ) raises -> LLMResponse:
        """Call OpenAI with a custom system prompt."""
        var json_mod = Python.import_module("json")
        var urllib = Python.import_module("urllib.request")

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

        var req = urllib.Request(url)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", "Bearer " + api_key)
        req.data = String(str(payload)).encode()

        var response = urllib.urlopen(req)
        var body = response.read().decode("utf-8")
        var data = json_mod.loads(body)

        var content = String(str(data["choices"][0]["message"]["content"]))
        var usage = data.get("usage", {})
        var pt = Int(usage.get("prompt_tokens", 0))
        var ct = Int(usage.get("completion_tokens", 0))

        return LLMResponse(content, self.model, self.provider, pt, ct, "stop")

    fn _call_anthropic(self, prompt: String, api_key: String) raises -> LLMResponse:
        """Call the Anthropic Messages API."""
        return self._call_anthropic_with_system(prompt, self.system_prompt, api_key)

    fn _call_anthropic_with_system(
        self, prompt: String, system: String, api_key: String
    ) raises -> LLMResponse:
        """Call Anthropic with a custom system prompt."""
        var json_mod = Python.import_module("json")
        var urllib = Python.import_module("urllib.request")

        var url = "https://api.anthropic.com/v1/messages"

        var payload = json_mod.dumps(
            {
                "model": self.model,
                "max_tokens": self.max_tokens,
                "system": system,
                "messages": [{"role": "user", "content": prompt}],
            }
        )

        var req = urllib.Request(url)
        req.add_header("Content-Type", "application/json")
        req.add_header("x-api-key", api_key)
        req.add_header("anthropic-version", "2023-06-01")
        req.data = String(str(payload)).encode()

        var response = urllib.urlopen(req)
        var body = response.read().decode("utf-8")
        var data = json_mod.loads(body)

        var content = String(str(data["content"][0]["text"]))
        var usage = data.get("usage", {})
        var pt = Int(usage.get("input_tokens", 0))
        var ct = Int(usage.get("output_tokens", 0))
        var stop = String(str(data.get("stop_reason", "end_turn")))

        return LLMResponse(content, self.model, self.provider, pt, ct, stop)
