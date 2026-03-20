defmodule LangExtract.Orchestrator do
  @moduledoc """
  Wires the full extraction pipeline.

  Builds a prompt, calls the LLM provider, normalizes and parses the response,
  aligns extractions to source text, and returns enriched spans.

  When `:max_chunk_chars` is set, splits the source into chunks and processes
  them in parallel via `Task.async_stream`.
  """

  alias LangExtract.{Alignment.Span, Chunker, Client, Prompt}

  @spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
          {:ok, [Span.t()]} | {:error, term()}
  def run(%Client{} = client, source, %Prompt.Template{} = template, opts \\ []) do
    case Keyword.get(opts, :max_chunk_chars) do
      nil -> run_single(client, source, template, opts)
      max_chars -> run_chunked(client, source, template, max_chars, opts)
    end
  end

  defp run_single(client, source, template, opts) do
    prompt = Prompt.Builder.build(template, source)

    with {:ok, raw_output} <- client.provider.infer(prompt, client.options) do
      LangExtract.extract(source, raw_output, opts)
    end
  end

  defp run_chunked(client, source, template, max_chars, opts) do
    chunks = Chunker.chunk(source, max_chunk_chars: max_chars)

    if chunks == [] do
      {:ok, []}
    else
      max_concurrency = Keyword.get(opts, :max_concurrency, 3)

      chunks
      |> with_previous_text()
      |> Task.async_stream(
        fn {chunk, prev_text} -> process_chunk(client, chunk, template, prev_text, opts) end,
        ordered: true,
        max_concurrency: max_concurrency
      )
      |> collect_results()
    end
  end

  defp with_previous_text(chunks) do
    chunks
    |> Enum.reduce({[], nil}, fn chunk, {acc, prev} ->
      {[{chunk, prev} | acc], chunk.text}
    end)
    |> then(fn {pairs, _} -> Enum.reverse(pairs) end)
  end

  defp collect_results(stream) do
    Enum.reduce_while(stream, {:ok, []}, fn
      {:ok, {:ok, spans}}, {:ok, acc} ->
        {:cont, {:ok, [spans | acc]}}

      {:ok, {:error, _} = error}, _acc ->
        {:halt, error}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:task_error, reason}}}
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp process_chunk(client, chunk, template, prev_text, opts) do
    builder_opts = if prev_text, do: [previous_chunk: prev_text], else: []
    prompt = Prompt.Builder.build(template, chunk.text, builder_opts)

    with {:ok, raw_output} <- client.provider.infer(prompt, client.options),
         {:ok, spans} <- LangExtract.extract(chunk.text, raw_output, opts) do
      {:ok, adjust_offsets(spans, chunk.byte_start)}
    end
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
