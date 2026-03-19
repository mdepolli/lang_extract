defmodule LangExtract.Orchestrator do
  @moduledoc """
  Wires the full extraction pipeline.

  Builds a prompt, calls the LLM provider, normalizes and parses the response,
  aligns extractions to source text, and returns enriched spans.

  When `:max_chunk_size` is set, splits the source into chunks and processes
  them in parallel via `Task.async_stream`.
  """

  alias LangExtract.{
    Alignment.Aligner,
    Alignment.Span,
    Chunker,
    Client,
    Extraction,
    FormatHandler,
    Parser,
    Prompt
  }

  @spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
          {:ok, [Span.t()]} | {:error, term()}
  def run(%Client{} = client, source, %Prompt.Template{} = template, opts \\ []) do
    case Keyword.get(opts, :max_chunk_size) do
      nil -> run_single(client, source, template, opts)
      max_size -> run_chunked(client, source, template, max_size, opts)
    end
  end

  defp run_single(client, source, template, opts) do
    prompt = Prompt.Builder.build(template, source)

    with {:ok, raw_output} <- client.provider.infer(prompt, client.options),
         {:ok, normalized} <- FormatHandler.normalize(raw_output),
         {:ok, extractions} <- Parser.parse(normalized) do
      {:ok, enrich(extractions, source, opts)}
    end
  end

  defp run_chunked(client, source, template, max_size, opts) do
    chunks = Chunker.chunk(source, max_chunk_size: max_size)

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
    prev_texts = [nil | Enum.map(chunks, & &1.text) |> Enum.drop(-1)]
    Enum.zip(chunks, prev_texts)
  end

  defp collect_results(stream) do
    Enum.reduce_while(stream, {:ok, []}, fn
      {:ok, {:ok, spans}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ spans}}

      {:ok, {:error, _} = error}, _acc ->
        {:halt, error}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:task_error, reason}}}
    end)
  end

  defp process_chunk(client, chunk, template, prev_text, opts) do
    builder_opts = if prev_text, do: [previous_chunk: prev_text], else: []
    prompt = Prompt.Builder.build(template, chunk.text, builder_opts)

    with {:ok, raw_output} <- client.provider.infer(prompt, client.options),
         {:ok, normalized} <- FormatHandler.normalize(raw_output),
         {:ok, extractions} <- Parser.parse(normalized) do
      spans = enrich(extractions, chunk.text, opts)
      adjusted = adjust_offsets(spans, chunk.byte_start)
      {:ok, adjusted}
    end
  end

  defp enrich(extractions, source, opts) do
    texts = Enum.map(extractions, & &1.text)
    spans = Aligner.align(source, texts, opts)

    Enum.zip(extractions, spans)
    |> Enum.map(fn {%Extraction{} = extraction, %Span{} = span} ->
      %Span{span | class: extraction.class, attributes: extraction.attributes}
    end)
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
