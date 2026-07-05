# Telemetry

LangExtract emits [`:telemetry`](https://hexdocs.pm/telemetry) spans at
three levels. Attach handlers to feed dashboards, logs, or cost tracking —
the library's own benchmark suite is built on these same events.

## Events

| Event | Measurements | Metadata |
| ----- | ------------ | -------- |
| `[:lang_extract, :document, :start]` | `system_time` | `source_bytes` |
| `[:lang_extract, :document, :stop]` | `duration`, `chunk_count`, `span_count`, `error_count` | `source_bytes` |
| `[:lang_extract, :chunk, :start]` | `system_time` | `byte_start`, `byte_end` |
| `[:lang_extract, :chunk, :stop]` | `duration`, `span_count` | `byte_start`, `byte_end`, `status` (`:ok` \| `:error`) |
| `[:lang_extract, :request, :start]` | `system_time` | `provider`, `model` |
| `[:lang_extract, :request, :stop]` | `duration`, `input_tokens`, `output_tokens` | `provider`, `model`, `status` |

All three spans also emit `:exception` events (standard `:telemetry.span/3`
semantics) if the wrapped work raises.

## Semantics worth knowing

- **Durations are in native time units** — convert with
  `System.convert_time_unit(duration, :native, :millisecond)`.
- **Request duration wraps the full HTTP call including transient
  retries** (429/5xx/transport, retried by Req) — it is the latency the
  pipeline experiences, not a single attempt.
- **Token measurements appear only when the provider reported usage**
  (Anthropic/OpenAI `"usage"`, Gemini `"usageMetadata"`). Treat missing
  keys as unknown, not zero.
- **Request `status` metadata** is the HTTP status code, or
  `:transport_error` when no response arrived.
- **Chunk `status` is only `:ok` or `:error`** — failure detail stays in
  the returned `ChunkError`, deliberately out of event metadata, so
  handlers can log freely without risking raw LLM payloads in logs.

## Example: cost tracking per document

```elixir
:telemetry.attach(
  "my-app-extraction-cost",
  [:lang_extract, :request, :stop],
  fn _event, measurements, metadata, _config ->
    MyApp.Metrics.increment("llm.tokens.output",
      Map.get(measurements, :output_tokens, 0),
      tags: [model: metadata.model]
    )
  end,
  nil
)
```

For a per-run summary instead of streaming metrics, collect request
events between `[:lang_extract, :document, :start]` and `:stop` — the
repo's benchmark runner (lib/mix/tasks/benchmark/run.ex) does exactly
this and is a working reference.
