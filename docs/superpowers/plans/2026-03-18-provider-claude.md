# Provider Behaviour + Claude Provider Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define an LLM provider behaviour and implement the Claude (Anthropic) provider using HTTPower + Finch.

**Architecture:** A `Provider` behaviour defines `infer/2`. The `Provider.Claude` module implements it by building an Anthropic Messages API request, delegating to HTTPower, and mapping the response. The logic is split into testable pure functions (`build_request/2`, `parse_response/1`) so tests don't need HTTP mocking.

**Tech Stack:** Elixir, HTTPower, Finch, Jason, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-18-provider-behaviour-claude-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `mix.exs` | Modify | Add `httpower` and `finch` dependencies |
| `lib/lang_extract/provider.ex` | Create | Behaviour definition with `infer/2` callback |
| `lib/lang_extract/provider/claude.ex` | Create | Claude provider: `infer/2`, `build_request/2`, `parse_response/1` |
| `test/lang_extract/provider/claude_test.exs` | Create | Unit tests for request building and response parsing |

---

## Chunk 1: Dependencies + Behaviour + Claude Provider

### Task 1: Add dependencies

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add httpower and finch to deps**

In `mix.exs`, update the `deps` function:

```elixir
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:httpower, "~> 0.20"},
      {:finch, "~> 0.19"}
    ]
  end
```

- [ ] **Step 2: Fetch dependencies**

Run: `mix deps.get`
Expected: Dependencies fetched successfully

- [ ] **Step 3: Verify compilation**

Run: `mix compile`
Expected: Compiles without errors

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "Add httpower and finch dependencies"
```

### Task 2: Provider behaviour

**Files:**
- Create: `lib/lang_extract/provider.ex`

- [ ] **Step 1: Create the behaviour module**

```elixir
# lib/lang_extract/provider.ex
defmodule LangExtract.Provider do
  @moduledoc """
  Behaviour for LLM inference providers.

  Each provider implements `infer/2` which takes a prompt string and returns
  the raw LLM response. Parsing and normalization are the caller's responsibility.
  """

  @callback infer(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/lang_extract/provider.ex
git commit -m "Add Provider behaviour"
```

### Task 3: Claude provider — request building tests

**Files:**
- Create: `test/lang_extract/provider/claude_test.exs`
- Create: `lib/lang_extract/provider/claude.ex`

- [ ] **Step 1: Write request building tests**

```elixir
# test/lang_extract/provider/claude_test.exs
defmodule LangExtract.Provider.ClaudeTest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.Claude

  describe "build_request/2" do
    test "builds correct request with default opts" do
      assert {:ok, {client, path, request_opts}} =
               Claude.build_request("Extract entities.", api_key: "sk-test")

      assert path == "/v1/messages"

      # Client has correct base URL and headers
      assert client.base_url == "https://api.anthropic.com"

      # Body contains expected fields
      body = Jason.decode!(request_opts[:body])
      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["max_tokens"] == 4096
      assert body["temperature"] == 0
      assert body["messages"] == [%{"role" => "user", "content" => "Extract entities."}]
    end

    test "custom opts override defaults" do
      assert {:ok, {_client, _path, request_opts}} =
               Claude.build_request("prompt",
                 api_key: "sk-test",
                 model: "claude-opus-4-20250514",
                 max_tokens: 1024,
                 temperature: 0.5
               )

      body = Jason.decode!(request_opts[:body])
      assert body["model"] == "claude-opus-4-20250514"
      assert body["max_tokens"] == 1024
      assert body["temperature"] == 0.5
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt", api_key: "sk-opts")

      assert client.options[:headers]["x-api-key"] == "sk-opts"

      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "falls back to ANTHROPIC_API_KEY env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt", [])

      assert client.options[:headers]["x-api-key"] == "sk-env"

      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "returns error when api key is missing" do
      System.delete_env("ANTHROPIC_API_KEY")

      assert {:error, :missing_api_key} = Claude.build_request("prompt", [])
    end

    test "custom base_url is used" do
      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt",
                 api_key: "sk-test",
                 base_url: "https://proxy.example.com"
               )

      assert client.base_url == "https://proxy.example.com"
    end
  end
end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `mix test test/lang_extract/provider/claude_test.exs --trace`
Expected: FAIL — `Claude` module not found

- [ ] **Step 3: Write the Claude provider**

```elixir
# lib/lang_extract/provider/claude.ex
defmodule LangExtract.Provider.Claude do
  @moduledoc """
  Claude (Anthropic) provider for LLM inference.

  Calls the Anthropic Messages API via HTTPower + Finch.
  """

  @behaviour LangExtract.Provider

  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 4096
  @default_temperature 0
  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"

  @impl true
  @spec infer(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def infer(prompt, opts \\ []) do
    with {:ok, {client, path, request_opts}} <- build_request(prompt, opts) do
      client
      |> HTTPower.post(path, request_opts)
      |> parse_response()
    end
  end

  @doc false
  @spec build_request(String.t(), keyword()) ::
          {:ok, {HTTPower.client(), String.t(), keyword()}} | {:error, :missing_api_key}
  def build_request(prompt, opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      temperature = Keyword.get(opts, :temperature, @default_temperature)
      base_url = Keyword.get(opts, :base_url, @default_base_url)

      client =
        HTTPower.new(
          base_url: base_url,
          headers: %{
            "x-api-key" => api_key,
            "anthropic-version" => @api_version,
            "content-type" => "application/json"
          }
        )

      body =
        Jason.encode!(%{
          "model" => model,
          "max_tokens" => max_tokens,
          "temperature" => temperature,
          "messages" => [%{"role" => "user", "content" => prompt}]
        })

      {:ok, {client, "/v1/messages", [body: body]}}
    end
  end

  @doc false
  @spec parse_response({:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def parse_response({:ok, %HTTPower.Response{status: 200, body: body}}) do
    extract_text(body)
  end

  def parse_response({:ok, %HTTPower.Response{status: 400, body: body}}) do
    {:error, {:bad_request, body}}
  end

  def parse_response({:ok, %HTTPower.Response{status: 401}}) do
    {:error, :unauthorized}
  end

  def parse_response({:ok, %HTTPower.Response{status: 429}}) do
    {:error, :rate_limited}
  end

  def parse_response({:ok, %HTTPower.Response{status: status}}) when status >= 500 do
    {:error, :server_error}
  end

  def parse_response({:ok, %HTTPower.Response{status: status, body: body}}) do
    {:error, {:api_error, status, body}}
  end

  def parse_response({:error, %HTTPower.Error{reason: reason}}) do
    {:error, {:request_error, reason}}
  end

  defp extract_text(%{"content" => [_ | _] = blocks}) do
    case Enum.find(blocks, &(&1["type"] == "text")) do
      %{"text" => text} when is_binary(text) -> {:ok, text}
      _ -> {:error, :empty_response}
    end
  end

  defp extract_text(_), do: {:error, :empty_response}
end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `mix test test/lang_extract/provider/claude_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/provider/claude.ex test/lang_extract/provider/claude_test.exs
git commit -m "Add Claude provider with request building"
```

### Task 4: Claude provider — response parsing tests

**Files:**
- Modify: `test/lang_extract/provider/claude_test.exs`

- [ ] **Step 1: Add response parsing tests**

```elixir
  describe "parse_response/1" do
    test "extracts text from successful response" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "content" => [%{"type" => "text", "text" => "extracted entities here"}]
        }
      }

      assert {:ok, "extracted entities here"} = Claude.parse_response({:ok, response})
    end

    test "extracts first text block from multiple content blocks" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "content" => [
            %{"type" => "thinking", "thinking" => "let me reason..."},
            %{"type" => "text", "text" => "the actual response"}
          ]
        }
      }

      assert {:ok, "the actual response"} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when no text content blocks" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"content" => [%{"type" => "thinking", "thinking" => "hmm"}]}
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when content is empty" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"content" => []}
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when body has no content key" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"something" => "else"}
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when body is not a map" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: "not json"
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request with body" do
      response = %HTTPower.Response{
        status: 400,
        headers: %{},
        body: %{"error" => %{"message" => "invalid model"}}
      }

      assert {:error, {:bad_request, %{"error" => _}}} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %HTTPower.Response{status: 401, headers: %{}, body: %{}}
      assert {:error, :unauthorized} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %HTTPower.Response{status: 429, headers: %{}, body: %{}}
      assert {:error, :rate_limited} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %HTTPower.Response{status: 500, headers: %{}, body: %{}}
      assert {:error, :server_error} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 503 to server_error" do
      response = %HTTPower.Response{status: 503, headers: %{}, body: %{}}
      assert {:error, :server_error} = Claude.parse_response({:ok, response})
    end

    test "maps other HTTP errors to api_error" do
      response = %HTTPower.Response{status: 418, headers: %{}, body: %{"error" => "teapot"}}
      assert {:error, {:api_error, 418, _}} = Claude.parse_response({:ok, response})
    end

    test "maps HTTPower error to request_error" do
      error = %HTTPower.Error{reason: :timeout, message: "Request timeout"}
      assert {:error, {:request_error, :timeout}} = Claude.parse_response({:error, error})
    end

    test "maps connection refused to request_error" do
      error = %HTTPower.Error{reason: :econnrefused, message: "Connection refused"}
      assert {:error, {:request_error, :econnrefused}} = Claude.parse_response({:error, error})
    end
  end
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `mix test test/lang_extract/provider/claude_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/provider/claude_test.exs
git commit -m "Add Claude provider response parsing tests"
```

### Task 5: Integration test (optional)

**Files:**
- Modify: `test/lang_extract/provider/claude_test.exs`

- [ ] **Step 1: Add optional integration test**

```elixir
  describe "infer/2 integration" do
    @tag :external
    test "makes a real API call and returns a string response" do
      api_key = System.get_env("ANTHROPIC_API_KEY")

      if is_nil(api_key) do
        IO.puts("Skipping: ANTHROPIC_API_KEY not set")
      else
        assert {:ok, response} = Claude.infer("Respond with exactly: hello", api_key: api_key)
        assert is_binary(response)
        assert String.length(response) > 0
      end
    end
  end
```

- [ ] **Step 2: Configure ExUnit to exclude external tests by default**

In `test/test_helper.exs`, ensure external tests are excluded:

```elixir
ExUnit.start(exclude: [:external])
```

- [ ] **Step 3: Run default tests (should skip integration)**

Run: `mix test --trace`
Expected: ALL PASS, integration test excluded

- [ ] **Step 4: Commit**

```bash
git add test/lang_extract/provider/claude_test.exs test/test_helper.exs
git commit -m "Add optional Claude integration test"
```

### Task 6: Final verification

- [ ] **Step 1: Run the full test suite**

Run: `mix test --trace`
Expected: ALL PASS

- [ ] **Step 2: Verify no warnings**

Run: `mix compile --warnings-as-errors`
Expected: PASS
