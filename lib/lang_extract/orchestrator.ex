defmodule LangExtract.Orchestrator do
  @moduledoc """
  Wires the full extraction pipeline.

  Builds a prompt, calls the LLM provider, normalizes and parses the response,
  aligns extractions to source text, and returns enriched spans.

  Auto-chunks source text by default (1000 characters). Customize with
  `:max_chunk_chars`.
  """

  @default_max_chunk_chars 1000

  alias LangExtract.{Alignment.Span, Chunker, Client, Pipeline, Prompt}
  alias Pipeline.ChunkError
  alias Prompt.Template

  @spec run(Client.t(), String.t(), Template.t(), keyword()) ::
          {:ok, {[Span.t()], [ChunkError.t()]}} | {:error, term()}
  def run(%Client{} = client, source, %Template{} = template, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chunk_chars, @default_max_chunk_chars)
    max_concurrency = Keyword.get(opts, :max_concurrency, 3)
    timeout = Keyword.get(opts, :task_timeout, :infinity)

    source
    |> Chunker.chunk(max_chunk_chars: max_chars)
    |> Task.async_stream(
      fn chunk -> process_chunk(client, chunk, template, opts) end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: timeout
    )
    |> collect_results()
  end

  defp collect_results(stream) do
    Enum.reduce_while(stream, {[], []}, fn
      {:ok, {:ok, chunk_spans}}, {spans_acc, errors_acc} ->
        {:cont, {[chunk_spans | spans_acc], errors_acc}}

      {:ok, {:error, %ChunkError{} = error}}, {spans_acc, errors_acc} ->
        {:cont, {spans_acc, [error | errors_acc]}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:task_exit, reason}}}
    end)
    |> finalize_results()
  end

  defp finalize_results({:error, _} = error), do: error

  defp finalize_results({spans, errors}) do
    spans = spans |> Enum.reverse() |> List.flatten()
    {:ok, {spans, Enum.reverse(errors)}}
  end

  defp process_chunk(client, chunk, template, opts) do
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
