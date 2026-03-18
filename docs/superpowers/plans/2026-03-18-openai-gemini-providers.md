# OpenAI + Gemini Providers Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenAI-compatible and Gemini providers implementing the existing `Provider` behaviour.

**Architecture:** Both follow the Claude provider pattern: `build_request/2` (pure) → `HTTPower.post/3` → `parse_response/1` (pure). Each is self-contained with no changes to existing modules. OpenAI uses Bearer auth + optional JSON mode; Gemini uses query-param auth + REST API.

**Tech Stack:** Elixir, HTTPower, Jason, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-18-openai-gemini-providers-design.md`

**Reference:** `lib/lang_extract/provider/claude.ex` — follow this pattern exactly.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/lang_extract/provider/openai.ex` | Create | OpenAI Chat Completions provider |
| `test/lang_extract/provider/openai_test.exs` | Create | OpenAI tests |
| `lib/lang_extract/provider/gemini.ex` | Create | Gemini REST API provider |
| `test/lang_extract/provider/gemini_test.exs` | Create | Gemini tests |

---

## Chunk 1: OpenAI Provider

### Task 1: OpenAI — request building tests + implementation

**Files:**
- Create: `lib/lang_extract/provider/openai.ex`
- Create: `test/lang_extract/provider/openai_test.exs`

- [ ] **Step 1: Write request building tests**

```elixir
# test/lang_extract/provider/openai_test.exs
defmodule LangExtract.Provider.OpenAITest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.OpenAI

  describe "build_request/2" do
    setup do
      original = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("OPENAI_API_KEY", original),
          else: System.delete_env("OPENAI_API_KEY")
      end)

      :ok
    end

    test "builds correct request with default opts (JSON mode on)" do
      assert {:ok, {client, path, request_opts}} =
               OpenAI.build_request("Extract entities.", api_key: "sk-test")

      assert path == "/v1/chat/completions"
      assert client.base_url == "https://api.openai.com"
      assert client.options[:headers]["authorization"] == "Bearer sk-test"
      assert client.options[:headers]["content-type"] == "application/json"

      body = Jason.decode!(request_opts[:body])
      assert body["model"] == "gpt-4o-mini"
      assert body["max_tokens"] == 4096
      assert body["temperature"] == 0
      assert body["response_format"] == %{"type" => "json_object"}

      [system_msg, user_msg] = body["messages"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "Respond with JSON."
      assert user_msg == %{"role" => "user", "content" => "Extract entities."}
    end

    test "json_mode: false omits response_format and system message" do
      assert {:ok, {_client, _path, request_opts}} =
               OpenAI.build_request("prompt", api_key: "sk-test", json_mode: false)

      body = Jason.decode!(request_opts[:body])
      refute Map.has_key?(body, "response_format")
      assert body["messages"] == [%{"role" => "user", "content" => "prompt"}]
    end

    test "custom opts override defaults" do
      assert {:ok, {_client, _path, request_opts}} =
               OpenAI.build_request("prompt",
                 api_key: "sk-test",
                 model: "gpt-4o",
                 max_tokens: 1024,
                 temperature: 0.7
               )

      body = Jason.decode!(request_opts[:body])
      assert body["model"] == "gpt-4o"
      assert body["max_tokens"] == 1024
      assert body["temperature"] == 0.7
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("OPENAI_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               OpenAI.build_request("prompt", api_key: "sk-opts")

      assert client.options[:headers]["authorization"] == "Bearer sk-opts"
    end

    test "falls back to OPENAI_API_KEY env var" do
      System.put_env("OPENAI_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               OpenAI.build_request("prompt", [])

      assert client.options[:headers]["authorization"] == "Bearer sk-env"
    end

    test "returns error when api key is missing" do
      System.delete_env("OPENAI_API_KEY")
      assert {:error, :missing_api_key} = OpenAI.build_request("prompt", [])
    end

    test "custom base_url for compatible endpoints" do
      assert {:ok, {client, _path, _request_opts}} =
               OpenAI.build_request("prompt",
                 api_key: "sk-test",
                 base_url: "http://localhost:11434"
               )

      assert client.base_url == "http://localhost:11434"
    end
  end
end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `mix test test/lang_extract/provider/openai_test.exs --trace`
Expected: FAIL — `OpenAI` module not found

- [ ] **Step 3: Write the OpenAI provider**

```elixir
# lib/lang_extract/provider/openai.ex
defmodule LangExtract.Provider.OpenAI do
  @moduledoc """
  OpenAI-compatible provider for LLM inference.

  Calls the OpenAI Chat Completions API. Works with OpenAI, Azure OpenAI,
  and any OpenAI-compatible endpoint (vLLM, LiteLLM, Ollama).
  """

  @behaviour LangExtract.Provider

  @default_model "gpt-4o-mini"
  @default_max_tokens 4096
  @default_temperature 0
  @default_base_url "https://api.openai.com"

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
    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    if api_key in [nil, ""] do
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      temperature = Keyword.get(opts, :temperature, @default_temperature)
      base_url = Keyword.get(opts, :base_url, @default_base_url)
      json_mode = Keyword.get(opts, :json_mode, true)

      client =
        HTTPower.new(
          base_url: base_url,
          headers: %{
            "authorization" => "Bearer #{api_key}",
            "content-type" => "application/json"
          }
        )

      messages =
        if json_mode do
          [
            %{"role" => "system", "content" => "Respond with JSON."},
            %{"role" => "user", "content" => prompt}
          ]
        else
          [%{"role" => "user", "content" => prompt}]
        end

      payload = %{
        "model" => model,
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "messages" => messages
      }

      payload =
        if json_mode do
          Map.put(payload, "response_format", %{"type" => "json_object"})
        else
          payload
        end

      {:ok, {client, "/v1/chat/completions", [body: Jason.encode!(payload)]}}
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

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp extract_text(_), do: {:error, :empty_response}
end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `mix test test/lang_extract/provider/openai_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/provider/openai.ex test/lang_extract/provider/openai_test.exs
git commit -m "Add OpenAI-compatible provider"
```

### Task 2: OpenAI — response parsing tests

**Files:**
- Modify: `test/lang_extract/provider/openai_test.exs`

- [ ] **Step 1: Add response parsing tests**

```elixir
  describe "parse_response/1" do
    test "extracts content from successful response" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "choices" => [
            %{"message" => %{"content" => "extracted data"}, "finish_reason" => "stop"}
          ]
        }
      }

      assert {:ok, "extracted data"} = OpenAI.parse_response({:ok, response})
    end

    test "extracts first choice from multiple choices" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "choices" => [
            %{"message" => %{"content" => "first"}, "finish_reason" => "stop"},
            %{"message" => %{"content" => "second"}, "finish_reason" => "stop"}
          ]
        }
      }

      assert {:ok, "first"} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when choices is empty" do
      response = %HTTPower.Response{status: 200, headers: %{}, body: %{"choices" => []}}
      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when content is nil" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"choices" => [%{"message" => %{"content" => nil}}]}
      }

      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when body has no choices" do
      response = %HTTPower.Response{status: 200, headers: %{}, body: %{}}
      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request" do
      response = %HTTPower.Response{status: 400, headers: %{}, body: %{"error" => "bad"}}
      assert {:error, {:bad_request, _}} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %HTTPower.Response{status: 401, headers: %{}, body: %{}}
      assert {:error, :unauthorized} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %HTTPower.Response{status: 429, headers: %{}, body: %{}}
      assert {:error, :rate_limited} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %HTTPower.Response{status: 500, headers: %{}, body: %{}}
      assert {:error, :server_error} = OpenAI.parse_response({:ok, response})
    end

    test "maps other HTTP errors to api_error" do
      response = %HTTPower.Response{status: 418, headers: %{}, body: %{}}
      assert {:error, {:api_error, 418, _}} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTPower error to request_error" do
      error = %HTTPower.Error{reason: :timeout, message: "Request timeout"}
      assert {:error, {:request_error, :timeout}} = OpenAI.parse_response({:error, error})
    end
  end
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `mix test test/lang_extract/provider/openai_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/provider/openai_test.exs
git commit -m "Add OpenAI response parsing tests"
```

---

## Chunk 2: Gemini Provider

### Task 3: Gemini — request building tests + implementation

**Files:**
- Create: `lib/lang_extract/provider/gemini.ex`
- Create: `test/lang_extract/provider/gemini_test.exs`

- [ ] **Step 1: Write request building tests**

```elixir
# test/lang_extract/provider/gemini_test.exs
defmodule LangExtract.Provider.GeminiTest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.Gemini

  describe "build_request/2" do
    setup do
      original = System.get_env("GEMINI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("GEMINI_API_KEY", original),
          else: System.delete_env("GEMINI_API_KEY")
      end)

      :ok
    end

    test "builds correct request with default opts" do
      assert {:ok, {client, path, request_opts}} =
               Gemini.build_request("Extract entities.", api_key: "gm-test")

      assert path == "/v1beta/models/gemini-2.0-flash:generateContent?key=gm-test"
      assert client.base_url == "https://generativelanguage.googleapis.com"
      assert client.options[:headers]["content-type"] == "application/json"
      # No auth header — key is in query param
      refute Map.has_key?(client.options[:headers], "authorization")
      refute Map.has_key?(client.options[:headers], "x-api-key")

      body = Jason.decode!(request_opts[:body])

      assert body["contents"] == [
               %{"parts" => [%{"text" => "Extract entities."}]}
             ]

      config = body["generationConfig"]
      assert config["temperature"] == 0
      assert config["maxOutputTokens"] == 4096
      assert config["responseMimeType"] == "application/json"
    end

    test "custom opts override defaults" do
      assert {:ok, {_client, path, request_opts}} =
               Gemini.build_request("prompt",
                 api_key: "gm-test",
                 model: "gemini-2.0-pro",
                 max_tokens: 2048,
                 temperature: 0.3
               )

      assert path =~ "gemini-2.0-pro"

      body = Jason.decode!(request_opts[:body])
      config = body["generationConfig"]
      assert config["maxOutputTokens"] == 2048
      assert config["temperature"] == 0.3
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("GEMINI_API_KEY", "gm-env")

      assert {:ok, {_client, path, _request_opts}} =
               Gemini.build_request("prompt", api_key: "gm-opts")

      assert path =~ "?key=gm-opts"
    end

    test "falls back to GEMINI_API_KEY env var" do
      System.put_env("GEMINI_API_KEY", "gm-env")

      assert {:ok, {_client, path, _request_opts}} =
               Gemini.build_request("prompt", [])

      assert path =~ "?key=gm-env"
    end

    test "returns error when api key is missing" do
      System.delete_env("GEMINI_API_KEY")
      assert {:error, :missing_api_key} = Gemini.build_request("prompt", [])
    end

    test "custom base_url is used" do
      assert {:ok, {client, _path, _request_opts}} =
               Gemini.build_request("prompt",
                 api_key: "gm-test",
                 base_url: "https://custom.api.com"
               )

      assert client.base_url == "https://custom.api.com"
    end
  end
end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `mix test test/lang_extract/provider/gemini_test.exs --trace`
Expected: FAIL — `Gemini` module not found

- [ ] **Step 3: Write the Gemini provider**

```elixir
# lib/lang_extract/provider/gemini.ex
defmodule LangExtract.Provider.Gemini do
  @moduledoc """
  Gemini provider for LLM inference.

  Calls the Google Gemini REST API directly (no SDK).
  """

  @behaviour LangExtract.Provider

  @default_model "gemini-2.0-flash"
  @default_max_tokens 4096
  @default_temperature 0
  @default_base_url "https://generativelanguage.googleapis.com"

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
    api_key = Keyword.get(opts, :api_key) || System.get_env("GEMINI_API_KEY")

    if api_key in [nil, ""] do
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      temperature = Keyword.get(opts, :temperature, @default_temperature)
      base_url = Keyword.get(opts, :base_url, @default_base_url)

      client =
        HTTPower.new(
          base_url: base_url,
          headers: %{"content-type" => "application/json"}
        )

      path = "/v1beta/models/#{model}:generateContent?key=#{api_key}"

      body =
        Jason.encode!(%{
          "contents" => [%{"parts" => [%{"text" => prompt}]}],
          "generationConfig" => %{
            "temperature" => temperature,
            "maxOutputTokens" => max_tokens,
            "responseMimeType" => "application/json"
          }
        })

      {:ok, {client, path, [body: body]}}
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

  defp extract_text(%{
         "candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]
       })
       when is_binary(text) do
    {:ok, text}
  end

  defp extract_text(_), do: {:error, :empty_response}
end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `mix test test/lang_extract/provider/gemini_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/provider/gemini.ex test/lang_extract/provider/gemini_test.exs
git commit -m "Add Gemini provider"
```

### Task 4: Gemini — response parsing tests

**Files:**
- Modify: `test/lang_extract/provider/gemini_test.exs`

- [ ] **Step 1: Add response parsing tests**

```elixir
  describe "parse_response/1" do
    test "extracts text from successful response" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "extracted data"}]},
              "finishReason" => "STOP"
            }
          ]
        }
      }

      assert {:ok, "extracted data"} = Gemini.parse_response({:ok, response})
    end

    test "extracts first text part from multiple parts" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "first"}, %{"text" => "second"}]
              },
              "finishReason" => "STOP"
            }
          ]
        }
      }

      assert {:ok, "first"} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when candidates is empty" do
      response = %HTTPower.Response{status: 200, headers: %{}, body: %{"candidates" => []}}
      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when content is absent (safety blocked)" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "candidates" => [%{"finishReason" => "SAFETY"}]
        }
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when parts is empty" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "candidates" => [%{"content" => %{"parts" => []}}]
        }
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when body has no candidates" do
      response = %HTTPower.Response{status: 200, headers: %{}, body: %{}}
      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request" do
      response = %HTTPower.Response{status: 400, headers: %{}, body: %{"error" => "bad"}}
      assert {:error, {:bad_request, _}} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %HTTPower.Response{status: 401, headers: %{}, body: %{}}
      assert {:error, :unauthorized} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %HTTPower.Response{status: 429, headers: %{}, body: %{}}
      assert {:error, :rate_limited} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %HTTPower.Response{status: 500, headers: %{}, body: %{}}
      assert {:error, :server_error} = Gemini.parse_response({:ok, response})
    end

    test "maps other HTTP errors to api_error" do
      response = %HTTPower.Response{status: 418, headers: %{}, body: %{}}
      assert {:error, {:api_error, 418, _}} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTPower error to request_error" do
      error = %HTTPower.Error{reason: :timeout, message: "Request timeout"}
      assert {:error, {:request_error, :timeout}} = Gemini.parse_response({:error, error})
    end
  end
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `mix test test/lang_extract/provider/gemini_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/provider/gemini_test.exs
git commit -m "Add Gemini response parsing tests"
```

---

## Chunk 3: Final Verification

### Task 5: Full test suite

- [ ] **Step 1: Run the full test suite**

Run: `mix test --trace`
Expected: ALL PASS

- [ ] **Step 2: Verify no warnings**

Run: `mix compile --warnings-as-errors`
Expected: PASS
