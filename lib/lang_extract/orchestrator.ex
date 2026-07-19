defmodule LangExtract.Orchestrator do
  @moduledoc """
  Wires the full extraction pipeline.

  Builds a prompt, calls the LLM provider, normalizes and parses the response,
  aligns extractions to source text, and returns enriched spans.

  Auto-chunks source text by default (1000 characters). Customize with
  `:max_chunk_chars`.

  Two consumption modes over one chunk pipeline: `run/4` collects everything
  and restores document order; `stream/4` yields each chunk's outcome the
  moment it completes.

  Internal — no stability guarantees; see the README's "Stability"
  section. Documented because it explains how the library works, not
  because it is API.
  """

  @default_max_chunk_chars 1000
  # Matches upstream langextract's max_workers default.
  @default_max_concurrency 10

  alias LangExtract.{
    Chunker,
    ChunkError,
    ChunkResult,
    Client,
    Pipeline,
    Prompt,
    Provider,
    Result,
    Span,
    Template
  }

  alias Provider.Response

  # run/4 is literally a consumer of stream/4 — one code path, no drift.
  # Every failure is per-chunk: a task exit arrives from the stream as a
  # ChunkError carrying its byte range and accumulates like any other
  # error, so collect/1 cannot fail and returns the Result bare.
  @spec run(Client.t(), String.t(), Template.t(), keyword()) :: Result.t()
  def run(%Client{} = client, source, %Template{} = template, opts \\ []) do
    client
    |> stream(source, template, opts)
    |> collect()
  end

  # The one collector behind both run/4s: LangExtract.run/4 and
  # Runner.run/4 differ only in which stream they hand it.
  @doc false
  @spec collect(Enumerable.t()) :: Result.t()
  def collect(events) do
    {results, errors} =
      Enum.reduce(events, {[], []}, fn
        {:ok, %ChunkResult{} = result}, {results, errors} -> {[result | results], errors}
        {:error, %ChunkError{} = error}, {results, errors} -> {results, [error | errors]}
      end)

    assemble_results(results, errors)
  end

  # Document order restored from unordered per-chunk events.
  @spec assemble_results([ChunkResult.t()], [ChunkError.t()]) :: Result.t()
  defp assemble_results(results, errors) do
    spans =
      results
      |> Enum.sort_by(& &1.byte_start)
      |> Enum.flat_map(& &1.spans)

    %Result{
      spans: spans,
      errors: Enum.sort_by(errors, & &1.byte_start),
      usage: total_usage(results)
    }
  end

  # nil only when no chunk reported usage; with partial reporting the
  # totals cover the chunks that did (documented on Result).
  defp total_usage(results) do
    case results |> Enum.map(& &1.usage) |> Enum.reject(&is_nil/1) do
      [] ->
        nil

      usages ->
        %{
          input_tokens: usages |> Enum.map(& &1.input_tokens) |> Enum.sum(),
          output_tokens: usages |> Enum.map(& &1.output_tokens) |> Enum.sum()
        }
    end
  end

  @spec stream(Client.t(), String.t(), Template.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, source, %Template{} = template, opts \\ []) do
    chunks = chunk_source(source, opts)
    metadata = %{source_bytes: byte_size(source)}

    client
    |> chunk_stream(chunks, template, opts)
    |> Stream.map(&public_event/1)
    |> with_document_events(length(chunks), metadata)
  end

  @doc false
  @spec chunk_source(String.t(), keyword()) :: [Chunker.Chunk.t()]
  def chunk_source(source, opts) do
    max_chars = Keyword.get(opts, :max_chunk_chars, @default_max_chunk_chars)
    Chunker.chunk(source, max_chunk_chars: max_chars)
  end

  # The shared lazy core: unordered task stream of {chunk, result} pairs.
  # ordered: true would let one slow chunk gate every later launch, capping
  # in-flight work at delivered + max_concurrency.
  defp chunk_stream(client, chunks, template, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    timeout = Keyword.get(opts, :task_timeout, :infinity)
    infer_fun = fn prompt -> client.provider.infer(prompt, Client.infer_opts(client)) end

    Task.async_stream(
      chunks,
      fn chunk -> {chunk, process_chunk(chunk, template, opts, infer_fun)} end,
      ordered: false,
      max_concurrency: max_concurrency,
      timeout: timeout,
      # :kill_task turns a chunk timeout into a stream element instead of
      # exiting the calling process; zip_input_on_exit keeps the chunk
      # identity so stream/4 can report which byte range timed out.
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
  end

  defp public_event({:ok, {_chunk, {:ok, %ChunkResult{} = result}}}) do
    {:ok, result}
  end

  defp public_event({:ok, {_chunk, {:error, %ChunkError{} = error}}}) do
    {:error, error}
  end

  # Task-level failures stay per-chunk in stream mode: the surviving chunks
  # keep flowing, and the dead one is reported with its byte range. Only
  # :timeout reaches this clause — the stream is linked, so a crashing task
  # exits the caller (the Runner's nolink Delivery is what converts crashes).
  defp public_event({:exit, {chunk, reason}}) do
    {:error, ChunkError.from_chunk(chunk, {:task_exit, reason})}
  end

  # Document telemetry for lazy consumption: :start fires at first demand,
  # :stop when the stream ends — including early halts, with the counts
  # accumulated so far. Event shapes mirror :telemetry.span/3. Shared with
  # the Runner's stream, which wraps its own delivery mechanism.
  @doc false
  @spec with_document_events(Enumerable.t(), non_neg_integer(), map()) :: Enumerable.t()
  def with_document_events(events, chunk_count, metadata) do
    metadata = Map.put(metadata, :telemetry_span_context, make_ref())

    Stream.transform(
      events,
      fn ->
        :telemetry.execute(
          [:lang_extract, :document, :start],
          %{monotonic_time: System.monotonic_time(), system_time: System.system_time()},
          metadata
        )

        {System.monotonic_time(), %{span_count: 0, error_count: 0}}
      end,
      fn event, {started, counts} ->
        {[event], {started, count_event(counts, event)}}
      end,
      fn {started, counts} ->
        monotonic_time = System.monotonic_time()

        :telemetry.execute(
          [:lang_extract, :document, :stop],
          Map.merge(counts, %{
            duration: monotonic_time - started,
            monotonic_time: monotonic_time,
            chunk_count: chunk_count
          }),
          metadata
        )
      end
    )
  end

  defp count_event(counts, {:ok, %ChunkResult{spans: spans}}) do
    %{counts | span_count: counts.span_count + length(spans)}
  end

  defp count_event(counts, {:error, %ChunkError{}}) do
    %{counts | error_count: counts.error_count + 1}
  end

  # The per-chunk pipeline, shared with the Runner: prompt → infer_fun →
  # parse → align, inside the chunk telemetry span. infer_fun is where the
  # two modes differ — direct provider call here, budget-scheduled
  # Runner.Request there.
  @doc false
  @spec process_chunk(
          Chunker.Chunk.t(),
          Template.t(),
          keyword(),
          (String.t() -> {:ok, Response.t()} | {:error, term()})
        ) :: {:ok, ChunkResult.t()} | {:error, ChunkError.t()}
  def process_chunk(chunk, template, opts, infer_fun) do
    metadata = %{byte_start: chunk.byte_start, byte_end: chunk.byte_end}

    :telemetry.span([:lang_extract, :chunk], metadata, fn ->
      result = extract_chunk(chunk, template, opts, infer_fun)

      {result, chunk_measurements(result), Map.put(metadata, :status, result_status(result))}
    end)
  end

  defp extract_chunk(chunk, template, opts, infer_fun) do
    prompt = Prompt.Builder.build(template, chunk.text)

    with {:ok, %Response{text: raw_output, usage: usage}} <- infer_fun.(prompt),
         {:ok, spans} <- Pipeline.extract(chunk.text, raw_output, opts) do
      {:ok, ChunkResult.from_chunk(chunk, adjust_offsets(spans, chunk.byte_start), usage)}
    else
      {:error, reason} -> {:error, ChunkError.from_chunk(chunk, reason)}
    end
  end

  defp chunk_measurements({:ok, %ChunkResult{spans: spans}}), do: %{span_count: length(spans)}
  defp chunk_measurements({:error, _chunk_error}), do: %{span_count: 0}

  # The ChunkError reason can embed the raw LLM payload; keep it out of
  # event metadata so handlers can log freely.
  defp result_status({:ok, _spans}), do: :ok
  defp result_status({:error, _chunk_error}), do: :error

  defp adjust_offsets(spans, byte_offset) do
    Enum.map(spans, fn
      %Span{byte_start: nil} = span ->
        span

      %Span{byte_start: bs, byte_end: be} = span ->
        %Span{span | byte_start: bs + byte_offset, byte_end: be + byte_offset}
    end)
  end
end
