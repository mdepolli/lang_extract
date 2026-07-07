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
| `[:lang_extract, :limiter, :wait]` | `duration` | `reason` (`:rpm` \| `:in_flight` \| `:retry_after`), `limiter` |
| `[:lang_extract, :chunk, :retry]` | `attempt` | `reason`, `limiter` |

The last two are emitted only by the supervised Runner — see the
[production guide](production.md).

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
- **With `stream/4`, document events follow consumption**: `:start` fires
  at first demand (not at stream construction) and `:stop` when the stream
  ends — including early halts, with the counts accumulated so far.

## Example: cost tracking per document

Attach a **module-qualified capture**, not an anonymous function —
`:telemetry` penalizes local/anonymous handlers (they can't be stored
efficiently and break on code reload). Any per-attachment state goes in
`attach`'s 4th argument, the **config**: telemetry stores it and passes it
back as your handler's 4th argument on every event. That is what lets one
static handler function back many attachments — here, a metric prefix
supplied at attach time:

```elixir
defmodule MyApp.ExtractionMetrics do
  def attach(metric_prefix) do
    :telemetry.attach(
      "extraction-cost-#{metric_prefix}",
      [:lang_extract, :request, :stop],
      &__MODULE__.handle/4,
      %{prefix: metric_prefix}
    )
  end

  # The %{prefix: ...} passed to attach/1 above arrives here as config.
  def handle(_event, measurements, %{model: model}, %{prefix: prefix}) do
    MyApp.Metrics.increment("#{prefix}.tokens.output",
      Map.get(measurements, :output_tokens, 0),
      tags: [model: model]
    )
  end
end
```

For a per-run summary instead of streaming metrics, collect request
events between `[:lang_extract, :document, :start]` and `:stop` — the
repo's benchmark runner (lib/mix/tasks/benchmark/run.ex) does exactly
this and is a working reference.
