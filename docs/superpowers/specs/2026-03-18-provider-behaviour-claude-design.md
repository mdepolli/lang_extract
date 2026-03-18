# LangExtract Provider Behaviour + Claude Provider — Design Spec

## Goal

Define a provider behaviour for LLM inference and implement the first provider (Claude via the Anthropic Messages API). This is the first of three sub-projects for LLM provider support:

1. **Provider behaviour + Claude** (this spec)
2. Additional providers (Gemini, OpenAI-compatible, Ollama)
3. Router + factory (model ID matching and provider selection)

## Architecture

```
PromptBuilder.build/3 → prompt string
                            ↓
                    Provider.infer/2  (behaviour)
                            ↓
                    Provider.Claude   (implementation)
                            ↓
                    HTTPower + Finch  (HTTP)
                            ↓
                    Anthropic Messages API
                            ↓
                    raw response string
                            ↓
                    FormatHandler.normalize/1 → Parser.parse/1
```

The provider is responsible only for sending a prompt and returning the raw response string. All parsing and normalization happens upstream/downstream.

## Modules

### `LangExtract.Provider` (behaviour)

Defines the contract that all LLM providers must implement.

```elixir
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

Single callback, minimal contract. Batch inference (`infer_batch`) can be added later as an optional callback if needed — it's additive.

### `LangExtract.Provider.Claude`

Calls the Anthropic Messages API via HTTPower + Finch.

**Public API:**

```elixir
@behaviour LangExtract.Provider

@spec infer(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
Provider.Claude.infer(prompt, opts \\ [])
```

**Options:**

| Option | Default | Description |
|---|---|---|
| `:api_key` | `System.get_env("ANTHROPIC_API_KEY")` | Anthropic API key |
| `:model` | `"claude-sonnet-4-20250514"` | Model ID |
| `:max_tokens` | `4096` | Maximum response tokens |
| `:temperature` | `0` | Sampling temperature (intentionally 0 for deterministic extraction; extended thinking is out of scope) |
| `:base_url` | `"https://api.anthropic.com"` | API base URL (overridable for proxies) |

**Request format:**

```
POST /v1/messages
Content-Type: application/json
x-api-key: <api_key>
anthropic-version: 2023-06-01

{
  "model": "<model>",
  "max_tokens": <max_tokens>,
  "temperature": <temperature>,
  "messages": [
    {"role": "user", "content": "<prompt>"}
  ]
}
```

**Response handling:**

HTTPower returns `{:ok, %HTTPower.Response{status, headers, body}}` or `{:error, %HTTPower.Error{reason, message}}`.

On HTTP 200, the response body (already JSON-decoded by HTTPower/Jason) looks like:

```json
{
  "content": [
    {"type": "text", "text": "...the LLM response..."}
  ]
}
```

Extract the first content block where `"type" == "text"` and return `{:ok, text}`.

If the body is not a map, has no `"content"` key, `"content"` is empty, or no block has `"type" == "text"`, return `{:error, :empty_response}`.

**Error handling:**

The provider returns `{:error, reason}` tuples — never raises. The API key is validated before making any HTTP call — a nil key returns `{:error, :missing_api_key}` immediately without hitting the network.

| Condition | Error |
|---|---|
| Missing API key (nil) — checked before HTTP call | `{:error, :missing_api_key}` |
| HTTP 400 (bad request — malformed request, invalid model ID) | `{:error, {:bad_request, body}}` |
| HTTP 401 | `{:error, :unauthorized}` |
| HTTP 429 | `{:error, :rate_limited}` |
| HTTP 500+ | `{:error, :server_error}` |
| Other non-2xx HTTP response | `{:error, {:api_error, status, body}}` |
| Network/connection failure (`%HTTPower.Error{}`) | `{:error, {:request_error, reason}}` where reason is the HTTPower error reason (e.g., `:timeout`, `:econnrefused`) |
| HTTP 200 but response missing text content | `{:error, :empty_response}` |

**HTTPower integration:**

The provider creates an HTTPower client via `HTTPower.new/1` configured with the base URL and auth headers:

```elixir
client = HTTPower.new(
  base_url: base_url,
  headers: %{
    "x-api-key" => api_key,
    "anthropic-version" => "2023-06-01",
    "content-type" => "application/json"
  }
)

HTTPower.post(client, "/v1/messages", body: Jason.encode!(payload))
```

HTTPower handles retries, circuit breaking, and connection management via Finch. The provider module itself stays thin — it builds the request, delegates to HTTPower, and maps the response.

## Dependencies

Add to `mix.exs`:

```elixir
{:httpower, "~> 0.20"},
{:finch, "~> 0.19"}
```

HTTPower requires at least one adapter. With Finch present, HTTPower auto-selects it. Jason is already a dependency and is reused for request body encoding.

## Testing Strategy

The provider's logic is split into two testable pure functions exposed as `@doc false` public functions:

- `build_request/2` — takes prompt + opts, returns `{:ok, {client, path, request_opts}}` or `{:error, :missing_api_key}`. Validates the API key before constructing the request.
- `parse_response/1` — takes an HTTPower result (`{:ok, %HTTPower.Response{}}` or `{:error, %HTTPower.Error{}}`), returns `{:ok, text}` or `{:error, reason}`.

These are unit-tested without any HTTP calls or mocking. The `infer/2` function is a thin wrapper: `build_request |> HTTPower.post |> parse_response`.

Mox is not needed for this step. It may be useful in sub-project 3 (router/factory) for mocking providers polymorphically.

An optional integration test tagged `@tag :external` exercises the real API when an `ANTHROPIC_API_KEY` is available. It is excluded from default test runs.

## File Structure

```
lib/lang_extract/
├── provider.ex              # NEW: behaviour definition
└── provider/
    └── claude.ex            # NEW: Claude (Anthropic) implementation
test/lang_extract/
└── provider/
    └── claude_test.exs      # NEW: unit tests + optional integration test
```

## Edge Cases to Test

### Request building (via build_request/2)
- Default opts produce correct request shape (client with base_url, headers, JSON body)
- Custom model, max_tokens, temperature are included in payload
- API key from opts takes precedence over env var
- Missing API key (nil in opts, no env var) returns `{:error, :missing_api_key}`

### Response parsing (via parse_response/1)
- Successful response (status 200) with text content → `{:ok, text}`
- Response with multiple content blocks → first text block extracted
- Response with no text content blocks → `{:error, :empty_response}`
- Response body is not a map → `{:error, :empty_response}`
- Response body has no "content" key → `{:error, :empty_response}`
- HTTP 400 → `{:error, {:bad_request, body}}`
- HTTP 401 → `{:error, :unauthorized}`
- HTTP 429 → `{:error, :rate_limited}`
- HTTP 500 → `{:error, :server_error}`
- Other non-2xx → `{:error, {:api_error, status, body}}`
- HTTPower error → `{:error, {:request_error, reason}}`

### Integration (optional, tagged @tag :external)
- Real API call with valid key returns a string response

## Out of Scope

- Batch inference (single prompt per call for now)
- Streaming responses
- Tool use / structured output mode
- Extended thinking (temperature 0 is intentional for deterministic extraction)
- System messages (prompt is a single user message)
- Token counting or usage tracking
- Provider router / factory (separate sub-project)
