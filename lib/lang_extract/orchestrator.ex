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
  """

  @default_max_chunk_chars 1000
  # Matches upstream langextract's max_workers default.
  @default_max_concurrency 10

  alias LangExtract.{Alignment.Span, Chunker, Client, Pipeline, Prompt, Template}
  alias Pipeline.{ChunkError, ChunkResult}

  # run/4 is literally a consumer of stream/4 — one code path, no drift.
  # Halting on a task-exit error kills outstanding tasks through the
  # stream's own cleanup and preserves the documented abandon-the-document
  # contract; document telemetry comes from the stream's events.
  @spec run(Client.t(), String.t(), Template.t(), keyword()) ::
          {:ok, {[Span.t()], [ChunkError.t()]}} | {:error, term()}
  def run(%Client{} = client, source, %Template{} = template, opts \\ []) do
    client
    |> stream(source, template, opts)
    |> Enum.reduce_while({[], []}, fn
      {:ok, %ChunkResult{} = result}, {results, errors} ->
        {:cont, {[result | results], errors}}

      {:error, %ChunkError{reason: {:task_exit, reason}}}, _acc ->
        {:halt, {:error, {:task_exit, reason}}}

      {:error, %ChunkError{} = error}, {results, errors} ->
        {:cont, {results, [error | errors]}}
    end)
    |> case do
      {:error, _} = error -> error
      {results, errors} -> {:ok, assemble_results(results, errors)}
    end
  end

  # Document order restored from unordered per-chunk events — shared by
  # Runner.run/4, whose collect differs only in never halting.
  @doc false
  @spec assemble_results([ChunkResult.t()], [ChunkError.t()]) ::
          {[Span.t()], [ChunkError.t()]}
  def assemble_results(results, errors) do
    spans =
      results
      |> Enum.sort_by(& &1.byte_start)
      |> Enum.flat_map(& &1.spans)

    {spans, Enum.sort_by(errors, & &1.byte_start)}
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

  defp public_event({:ok, {chunk, {:ok, spans}}}) do
    {:ok, %ChunkResult{byte_start: chunk.byte_start, byte_end: chunk.byte_end, spans: spans}}
  end

  defp public_event({:ok, {_chunk, {:error, %ChunkError{} = error}}}) do
    {:error, error}
  end

  # Task-level failures stay per-chunk in stream mode: the surviving chunks
  # keep flowing, and the dead one is reported with its byte range.
  defp public_event({:exit, {chunk, reason}}) do
    {:error,
     %ChunkError{
       byte_start: chunk.byte_start,
       byte_end: chunk.byte_end,
       reason: {:task_exit, reason}
     }}
  end

  # Document telemetry for lazy consumption: :start fires at first demand,
  # :stop when the stream ends — including early halts, with the counts
  # accumulated so far. Event shapes mirror :telemetry.span/3. Shared with
  # the Runner's stream, which wraps its own delivery mechanism.
  @doc false
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
  def process_chunk(chunk, template, opts, infer_fun) do
    metadata = %{byte_start: chunk.byte_start, byte_end: chunk.byte_end}

    :telemetry.span([:lang_extract, :chunk], metadata, fn ->
      result = extract_chunk(chunk, template, opts, infer_fun)

      {result, chunk_measurements(result), Map.put(metadata, :status, result_status(result))}
    end)
  end

  defp extract_chunk(chunk, template, opts, infer_fun) do
    prompt = Prompt.Builder.build(template, chunk.text)

    with {:ok, raw_output} <- infer_fun.(prompt),
         {:ok, spans} <- Pipeline.extract(chunk.text, raw_output, opts) do
      {:ok, adjust_offsets(spans, chunk.byte_start)}
    else
      {:error, reason} ->
        {:error,
         %ChunkError{
           byte_start: chunk.byte_start,
           byte_end: chunk.byte_end,
           reason: reason
         }}
    end
  end

  defp chunk_measurements({:ok, spans}), do: %{span_count: length(spans)}
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
