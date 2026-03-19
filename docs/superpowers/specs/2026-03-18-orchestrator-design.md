# LangExtract Orchestrator — Design Spec

## Goal

Wire the full extraction pipeline end-to-end: configure a client, build a prompt, call an LLM, normalize and parse the response, align extractions to source text, return enriched spans.

## Architecture

```
LangExtract.new(:claude, api_key: "sk-...")
  → %Client{provider: Provider.Claude, options: [...]}

LangExtract.run(client, source, template, opts)
  → Prompt.Builder.build(template, source)
  → provider.infer(prompt, client.options)
  → FormatHandler.normalize(raw_output)
  → Parser.parse(normalized)
  → Aligner.align(source, texts, opts)
  → zip + merge class/attributes onto spans
  → {:ok, [%Span{}]}
```

## Public API

### `LangExtract.new/2`

Creates a configured client for a specific provider.

```elixir
client = LangExtract.new(:claude, api_key: "sk-...", model: "claude-opus-4-20250514")
client = LangExtract.new(:openai, api_key: "sk-...", json_mode: false)
client = LangExtract.new(:gemini, api_key: "gm-...")
```

```elixir
@spec new(atom(), keyword()) :: Client.t()
def new(provider, opts \\ [])
```

The first argument is a provider shorthand atom. The mapping:

| Atom | Module |
|---|---|
| `:claude` | `LangExtract.Provider.Claude` |
| `:openai` | `LangExtract.Provider.OpenAI` |
| `:gemini` | `LangExtract.Provider.Gemini` |

Unknown atoms raise `ArgumentError`.

The second argument is the options keyword list — stored on the client and passed through to `provider.infer/2` at execution time. These are provider-specific options (api_key, model, max_tokens, temperature, base_url, etc.).

### `LangExtract.run/3,4`

Executes the full extraction pipeline.

```elixir
{:ok, spans} = LangExtract.run(client, source, template)
{:ok, spans} = LangExtract.run(client, source, template, fuzzy_threshold: 0.9)
```

```elixir
@spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
        {:ok, [Alignment.Span.t()]} | {:error, term()}
def run(client, source, template, opts \\ [])
```

**Options:** Execution-level concerns only.
- `:fuzzy_threshold` — passed through to `Aligner.align/3` (default 0.75)

**Return type:** Same `{:ok, [%Span{}]}` as the existing `extract/3`, with `class`, `attributes`, `byte_start`, `byte_end`, and `status` populated on each span.

**Error propagation:** The `with` chain propagates the first error from any step:
- Provider errors: `:missing_api_key`, `:unauthorized`, `:rate_limited`, `:server_error`, `{:bad_request, body}`, `{:api_error, status, body}`, `{:request_error, reason}`, `:empty_response`
- Format errors: `:invalid_format`
- Parser errors: `:invalid_json`, `:missing_extractions`

### Existing API unchanged

`LangExtract.align/3` and `LangExtract.extract/3` continue to work as before. `run/3,4` is additive.

## Modules

### `LangExtract.Client`

A struct holding the configured provider and its options.

```elixir
defmodule LangExtract.Client do
  @moduledoc """
  A configured LLM client for extraction.
  """

  @type t :: %__MODULE__{
          provider: module(),
          options: keyword()
        }

  @enforce_keys [:provider]
  defstruct [:provider, options: []]
end
```

### `LangExtract.Orchestrator`

The pipeline implementation. A single `run/4` function.

```elixir
@spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
        {:ok, [Alignment.Span.t()]} | {:error, term()}
def run(%Client{} = client, source, %Prompt.Template{} = template, opts \\ []) do
  prompt = Prompt.Builder.build(template, source)

  # FormatHandler.normalize/1 returns {:ok, map()} — a decoded map, not a JSON string.
  # Parser.parse/1 accepts both strings and maps.
  with {:ok, raw_output} <- client.provider.infer(prompt, client.options),
       {:ok, normalized} <- FormatHandler.normalize(raw_output),
       {:ok, extractions} <- Parser.parse(normalized) do
    # texts must come from the parsed (filtered) extractions list, not raw LLM output,
    # because Parser.parse/1 may have skipped invalid entries via flat_map.
    # This ensures length(texts) == length(spans) for the zip below.
    texts = Enum.map(extractions, & &1.text)
    spans = Alignment.Aligner.align(source, texts, opts)

    enriched =
      Enum.zip(extractions, spans)
      |> Enum.map(fn {extraction, span} ->
        %Alignment.Span{span | class: extraction.class, attributes: extraction.attributes}
      end)

    {:ok, enriched}
  end
end
```

### `LangExtract` (modified)

Add `new/2` and `run/3,4` as delegates.

```elixir
alias LangExtract.{Client, Orchestrator, Provider}

def new(provider, opts \\ []) do
  module = resolve_provider(provider)
  %Client{provider: module, options: opts}
end

def run(%Client{} = client, source, template, opts \\ []) do
  Orchestrator.run(client, source, template, opts)
end

defp resolve_provider(:claude), do: Provider.Claude
defp resolve_provider(:openai), do: Provider.OpenAI
defp resolve_provider(:gemini), do: Provider.Gemini

defp resolve_provider(other) do
  raise ArgumentError, "unknown provider: #{inspect(other)}. Expected :claude, :openai, or :gemini"
end
```

## File Structure

```
lib/lang_extract/
├── client.ex              # NEW: Client struct
├── orchestrator.ex        # NEW: run/4 pipeline
├── lang_extract.ex        # MODIFIED: add new/2, run/3,4
```

## Testing Strategy

The orchestrator calls `provider.infer/2` which makes HTTP calls. Tests use `HTTPower.Test.stub` to mock the LLM response, then verify the full pipeline produces correct spans.

```elixir
setup do
  HTTPower.Test.setup()
end

test "full pipeline: prompt → LLM → parse → align → spans" do
  HTTPower.Test.stub(fn conn ->
    HTTPower.Test.json(conn, %{
      "content" => [%{"type" => "text", "text" => ~s({"extractions": [{"class": "word", "text": "fox"}]})}]
    })
  end)

  client = LangExtract.new(:claude, api_key: "sk-test")
  template = %Prompt.Template{description: "Extract words."}

  assert {:ok, [span]} = LangExtract.run(client, "the quick brown fox", template)
  assert span.class == "word"
  assert span.text == "fox"
  assert span.status == :exact
end
```

## Edge Cases to Test

### LangExtract.new/2
- Known provider atoms resolve correctly (`:claude`, `:openai`, `:gemini`)
- Unknown atom raises `ArgumentError`
- Options stored on client

### LangExtract.run/3,4
- Full pipeline happy path — stub returns valid extractions, spans align correctly
- Provider error propagates (e.g., stub returns 401)
- Invalid LLM output propagates (format handler returns `:invalid_format`)
- Empty extractions list — returns `{:ok, []}`
- `fuzzy_threshold` option passed through to aligner
- Multiple extractions aligned independently
- Extraction not found in source — returns `{:ok, [span]}` with `span.status == :not_found` (LLM hallucination)

**Note:** The test stub body must match the provider-specific response schema. The example above uses Claude's format (`content[].type/text`). OpenAI and Gemini stubs would need their respective formats (`choices[].message.content` and `candidates[].content.parts[].text`).

## Future: Chunking

Chunking will be added inside the orchestrator without changing the external API. The `run/4` function will:
1. Split source into chunks (sentence-aware)
2. Call the pipeline per chunk (with `previous_chunk` context)
3. Merge results across chunks

This is deferred until someone hits token limits.

## Out of Scope

- Chunking (future improvement, noted above)
- Multi-pass extraction with overlap resolution
- Streaming
- Batch inference across multiple documents
- Provider router / factory (resolved by `new/2`'s atom mapping)
