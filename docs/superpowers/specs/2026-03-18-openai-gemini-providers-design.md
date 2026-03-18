# LangExtract OpenAI + Gemini Providers — Design Spec

## Goal

Add two more LLM providers: OpenAI-compatible (Chat Completions API) and Gemini (REST API). Both implement the existing `LangExtract.Provider` behaviour.

This is sub-project 2 of 3 for LLM provider support:

1. ~~Provider behaviour + Claude~~ (done)
2. **OpenAI + Gemini providers** (this spec)
3. Router + factory (future)

## Architecture

Both providers follow the same pattern as Claude:

```
Provider.infer/2
  → build_request/2  (pure, @doc false, testable)
  → HTTPower.post/3
  → parse_response/1 (pure, @doc false, testable)
```

No changes to existing modules. Each provider is self-contained.

## Modules

### `LangExtract.Provider.OpenAI`

Calls the OpenAI Chat Completions API. Works with OpenAI, Azure OpenAI, and any OpenAI-compatible endpoint (vLLM, LiteLLM, Ollama's OpenAI mode).

**Public API:**

```elixir
@behaviour LangExtract.Provider

@spec infer(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
Provider.OpenAI.infer(prompt, opts \\ [])
```

**Options:**

| Option | Default | Description |
|---|---|---|
| `:api_key` | `System.get_env("OPENAI_API_KEY")` | API key |
| `:model` | `"gpt-4o-mini"` | Model ID |
| `:max_tokens` | `4096` | Maximum response tokens |
| `:temperature` | `0` | Sampling temperature |
| `:base_url` | `"https://api.openai.com"` | API base URL (overridable for compatible endpoints) |
| `:json_mode` | `true` | Include `response_format: {"type": "json_object"}` and system message. Set to `false` for endpoints that don't support it. |

**Request format:**

```
POST /v1/chat/completions
Content-Type: application/json
Authorization: Bearer <api_key>

{
  "model": "<model>",
  "max_tokens": <max_tokens>,
  "temperature": <temperature>,
  "response_format": {"type": "json_object"},
  "messages": [
    {"role": "system", "content": "Respond with JSON."},
    {"role": "user", "content": "<prompt>"}
  ]
}
```

The system message and `response_format` enable JSON mode (when `:json_mode` is `true`), ensuring the LLM responds with valid JSON rather than markdown-wrapped output. When `:json_mode` is `false`, both are omitted — useful for compatible endpoints that don't support JSON mode (Ollama, older models).

**Response handling:**

On HTTP 200, the response body looks like:

```json
{
  "choices": [
    {
      "message": {
        "content": "...the LLM response..."
      }
    }
  ]
}
```

Extract `choices[0].message.content` and return `{:ok, text}`.

If `choices` is empty, missing, or the first choice has no `message.content`, return `{:error, :empty_response}`. The `finish_reason` field is not checked — truncated responses (`"length"`) or content-filtered responses (`"content_filter"`) are returned as-is if content is present. The downstream FormatHandler/Parser will catch malformed extractions. Richer `finish_reason` handling is deferred to future work.

**`build_request/2` return shape:**

```elixir
@spec build_request(String.t(), keyword()) ::
        {:ok, {HTTPower.client(), String.t(), keyword()}} | {:error, :missing_api_key}
```

The client is created with `HTTPower.new(base_url: base_url, headers: %{"authorization" => "Bearer #{api_key}", "content-type" => "application/json"})`. The path is `"/v1/chat/completions"`.

**Auth:** Uses `Authorization: Bearer <api_key>` header (standard OpenAI auth).

**Error handling:** Same pattern as Claude:

| Condition | Error |
|---|---|
| Missing API key | `{:error, :missing_api_key}` |
| HTTP 400 | `{:error, {:bad_request, body}}` |
| HTTP 401 | `{:error, :unauthorized}` |
| HTTP 429 | `{:error, :rate_limited}` |
| HTTP 500+ | `{:error, :server_error}` |
| Other non-2xx | `{:error, {:api_error, status, body}}` |
| Network failure | `{:error, {:request_error, reason}}` |
| Empty response | `{:error, :empty_response}` |

### `LangExtract.Provider.Gemini`

Calls the Gemini REST API directly (no Google SDK).

**Public API:**

```elixir
@behaviour LangExtract.Provider

@spec infer(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
Provider.Gemini.infer(prompt, opts \\ [])
```

**Options:**

| Option | Default | Description |
|---|---|---|
| `:api_key` | `System.get_env("GEMINI_API_KEY")` | API key |
| `:model` | `"gemini-2.0-flash"` | Model ID |
| `:max_tokens` | `4096` | Maximum response tokens |
| `:temperature` | `0` | Sampling temperature |
| `:base_url` | `"https://generativelanguage.googleapis.com"` | API base URL |

**Request format:**

```
POST /v1beta/models/<model>:generateContent?key=<api_key>
Content-Type: application/json

{
  "contents": [
    {
      "parts": [{"text": "<prompt>"}]
    }
  ],
  "generationConfig": {
    "temperature": <temperature>,
    "maxOutputTokens": <max_tokens>,
    "responseMimeType": "application/json"
  }
}
```

Note: Gemini uses query parameter auth (`?key=<api_key>`) rather than a header. Since HTTPower does not support a `params:` option, the API key is appended to the path string directly in `build_request/2`. The `responseMimeType` field enables JSON output mode.

**`build_request/2` return shape:**

```elixir
@spec build_request(String.t(), keyword()) ::
        {:ok, {HTTPower.client(), String.t(), keyword()}} | {:error, :missing_api_key}
```

The client is created with `HTTPower.new(base_url: base_url, headers: %{"content-type" => "application/json"})` — no auth header. The path includes the model and query param: `"/v1beta/models/#{model}:generateContent?key=#{api_key}"`. Tests assert that the path contains `?key=` and the client headers have no auth key.

**Response handling:**

On HTTP 200, the response body looks like:

```json
{
  "candidates": [
    {
      "content": {
        "parts": [
          {"text": "...the LLM response..."}
        ]
      },
      "finishReason": "STOP"
    }
  ]
}
```

Extract `candidates[0].content.parts[0].text` and return `{:ok, text}`.

If `candidates` is empty, missing, or the first candidate has no text part (e.g., `finishReason` is `"SAFETY"` or `"RECITATION"` and content is absent), return `{:error, :empty_response}`. Richer error codes for safety blocking are deferred to future work.

**Auth:** API key passed as query parameter `?key=<api_key>`. No auth header needed.

**Error handling:** Same pattern as Claude and OpenAI (same error table).

## Testing Strategy

Same approach as Claude: extract `build_request/2` and `parse_response/1` as `@doc false` public functions, test them as pure functions without HTTP mocking. Optional integration tests tagged `@tag :external`.

## File Structure

```
lib/lang_extract/provider/
├── claude.ex            # existing
├── openai.ex            # NEW
└── gemini.ex            # NEW
test/lang_extract/provider/
├── claude_test.exs      # existing
├── openai_test.exs      # NEW
└── gemini_test.exs      # NEW
```

## Edge Cases to Test

### OpenAI — Request building
- Default opts produce correct request shape (Bearer auth, JSON mode, system message)
- Custom model, max_tokens, temperature
- API key from opts takes precedence over `OPENAI_API_KEY` env var
- Missing API key returns `{:error, :missing_api_key}`
- Custom base_url for compatible endpoints
- `json_mode: false` omits `response_format` and system message

### OpenAI — Response parsing
- Successful response with content → `{:ok, text}`
- Empty choices list → `{:error, :empty_response}`
- Missing message content → `{:error, :empty_response}`
- All HTTP error codes (400, 401, 429, 500+, other)
- Network errors

### Gemini — Request building
- Default opts produce correct request shape (query param auth, generationConfig)
- API key appears in query parameter, not header
- Model ID embedded in path (`/v1beta/models/<model>:generateContent`)
- Custom model, max_tokens, temperature
- Missing API key returns `{:error, :missing_api_key}`

### Gemini — Response parsing
- Successful response with candidates → `{:ok, text}`
- Empty candidates list → `{:error, :empty_response}`
- Missing text part → `{:error, :empty_response}`
- Candidate present but content absent (safety blocked) → `{:error, :empty_response}`
- All HTTP error codes
- Network errors

### Integration (optional, tagged @tag :external)
- Real API call to each provider returns a string response

## Out of Scope

- Gemini structured output via `response_schema` (can be added later via opts passthrough)
- Gemini Vertex AI auth (API key only for now)
- OpenAI organization header
- Streaming responses
- Batch inference
- Provider router / factory (sub-project 3)
