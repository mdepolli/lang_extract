defmodule LangExtract.Orchestrator do
  @moduledoc """
  Wires the full extraction pipeline.

  Builds a prompt, calls the LLM provider, normalizes and parses the response,
  aligns extractions to source text, and returns enriched spans.

  Auto-chunks source text by default (1000 characters). Customize with
  `:max_chunk_chars`.
  """

  @default_max_chunk_chars 1000
  # Matches upstream langextract's max_workers default.
  @default_max_concurrency 10

  alias LangExtract.{Alignment.Span, Chunker, Client, Pipeline, Prompt}
  alias Pipeline.ChunkError
  alias Prompt.Template

  @spec run(Client.t(), String.t(), Template.t(), keyword()) ::
          {:ok, {[Span.t()], [ChunkError.t()]}} | {:error, term()}
  def run(%Client{} = client, source, %Template{} = template, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chunk_chars, @default_max_chunk_chars)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    timeout = Keyword.get(opts, :task_timeout, :infinity)

    chunks = Chunker.chunk(source, max_chunk_chars: max_chars)
    metadata = %{source_bytes: byte_size(source)}

    :telemetry.span([:lang_extract, :document], metadata, fn ->
      result =
        chunks
        |> Task.async_stream(
          fn chunk -> {chunk.byte_start, process_chunk(client, chunk, template, opts)} end,
          ordered: false,
          max_concurrency: max_concurrency,
          timeout: timeout
        )
        |> collect_results()

      measurements = Map.put(document_measurements(result), :chunk_count, length(chunks))
      {result, measurements, metadata}
    end)
  end

  defp document_measurements({:ok, {spans, errors}}) do
    %{span_count: length(spans), error_count: length(errors)}
  end

  defp document_measurements({:error, _reason}), do: %{}

  defp collect_results(stream) do
    Enum.reduce_while(stream, {[], []}, fn
      {:ok, {chunk_start, {:ok, chunk_spans}}}, {spans_acc, errors_acc} ->
        {:cont, {[{chunk_start, chunk_spans} | spans_acc], errors_acc}}

      {:ok, {_chunk_start, {:error, %ChunkError{} = error}}}, {spans_acc, errors_acc} ->
        {:cont, {spans_acc, [error | errors_acc]}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:task_exit, reason}}}
    end)
    |> finalize_results()
  end

  defp finalize_results({:error, _} = error), do: error

  # The stream is unordered — with ordered: true one slow chunk gates every
  # later launch, capping in-flight work at delivered + max_concurrency.
  # Document order is restored here by chunk position instead.
  defp finalize_results({tagged_spans, errors}) do
    spans =
      tagged_spans
      |> Enum.sort_by(fn {chunk_start, _spans} -> chunk_start end)
      |> Enum.flat_map(fn {_chunk_start, spans} -> spans end)

    {:ok, {spans, Enum.sort_by(errors, & &1.byte_start)}}
  end

  defp process_chunk(client, chunk, template, opts) do
    metadata = %{byte_start: chunk.byte_start, byte_end: chunk.byte_end}

    :telemetry.span([:lang_extract, :chunk], metadata, fn ->
      result = extract_chunk(client, chunk, template, opts)

      {result, chunk_measurements(result), Map.put(metadata, :status, result_status(result))}
    end)
  end

  defp extract_chunk(client, chunk, template, opts) do
    prompt = Prompt.Builder.build(template, chunk.text)

    with {:ok, raw_output} <- client.provider.infer(prompt, infer_opts(client)),
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

  defp infer_opts(%Client{} = client) do
    Keyword.put(client.options, :http_client, client.http_client)
  end

  defp adjust_offsets(spans, byte_offset) do
    Enum.map(spans, fn
      %Span{byte_start: nil} = span ->
        span

      %Span{byte_start: bs, byte_end: be} = span ->
        %Span{span | byte_start: bs + byte_offset, byte_end: be + byte_offset}
    end)
  end
end
