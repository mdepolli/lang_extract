defmodule LangExtract.Serializer do
  @moduledoc """
  Serialization and deserialization of extraction results.

  Converts between LangExtract structs and plain maps/JSON for storage,
  debugging, and interop with external systems. `result_to_map/2` /
  `result_from_map/1` cover the full `LangExtract.Result` (spans, errors,
  usage); `to_map/2` / `from_map/1` cover bare span lists (e.g. from
  `LangExtract.align/3`).

  Error reasons are open terms, so they serialize as their `inspect/1`
  rendering — JSON-safe, but one-way: a loaded `ChunkError` carries the
  rendered string, not the original term.
  """

  alias LangExtract.ChunkError
  alias LangExtract.Result
  alias LangExtract.Span

  @doc """
  Converts extraction results to a plain map.
  """
  @spec to_map(String.t(), [Span.t()]) :: map()
  def to_map(source, spans) do
    %{
      "text" => source,
      "extractions" => Enum.map(spans, &span_to_map/1)
    }
  end

  @doc """
  Converts a full `LangExtract.Result` and its source to a plain map.

  The map extends `to_map/2`'s shape with `"errors"` (see
  `chunk_error_to_map/1`) and `"usage"` (string-keyed token counts, or
  `nil` when the run reported none).
  """
  @spec result_to_map(String.t(), Result.t()) :: map()
  def result_to_map(source, %Result{} = result) do
    source
    |> to_map(result.spans)
    |> Map.merge(%{
      "errors" => Enum.map(result.errors, &chunk_error_to_map/1),
      "usage" => usage_to_map(result.usage)
    })
  end

  @doc """
  Converts a plain map back to `{source, %LangExtract.Result{}}`.

  Returns `{:error, :invalid_data}` if the shape or field types are wrong —
  validation is strict, so a decoded struct upholds the same invariants as
  a pipeline-produced one. Error reasons come back as the `inspect/1`
  strings `result_to_map/2` wrote.
  """
  @spec result_from_map(term()) :: {:ok, {String.t(), Result.t()}} | {:error, :invalid_data}
  def result_from_map(%{"text" => text, "extractions" => extractions, "errors" => errors} = map)
      when is_binary(text) and is_list(extractions) and is_list(errors) do
    with {:ok, spans} <- map_spans(extractions),
         {:ok, chunk_errors} <- map_chunk_errors(errors),
         {:ok, usage} <- usage_from_map(map["usage"]) do
      {:ok, {text, %Result{spans: spans, errors: chunk_errors, usage: usage}}}
    end
  end

  def result_from_map(_), do: {:error, :invalid_data}

  @doc """
  Converts a `LangExtract.ChunkError` to a plain map with string keys.

  The open `reason` term is rendered with `inspect/1` so the map is always
  JSON-encodable.
  """
  @spec chunk_error_to_map(ChunkError.t()) :: map()
  def chunk_error_to_map(%ChunkError{} = error) do
    %{
      "byte_start" => error.byte_start,
      "byte_end" => error.byte_end,
      "reason" => inspect(error.reason)
    }
  end

  @doc """
  Converts a single span to a plain map with string keys.
  """
  @spec span_to_map(Span.t()) :: map()
  def span_to_map(%Span{} = span) do
    %{
      "class" => span.class,
      "text" => span.text,
      "byte_start" => span.byte_start,
      "byte_end" => span.byte_end,
      "status" => Atom.to_string(span.status),
      "attributes" => span.attributes
    }
  end

  @doc """
  Converts a plain map back to extraction results.

  Returns `{:error, :invalid_data}` if the shape is wrong, an extraction
  has an unknown `"status"`, or field types don't match the `Span`
  invariants (located spans carry integer offsets, `not_found` spans
  carry `nil`).
  """
  @spec from_map(map()) :: {:ok, {String.t(), [Span.t()]}} | {:error, :invalid_data}
  def from_map(%{"text" => text, "extractions" => extractions})
      when is_binary(text) and is_list(extractions) do
    case map_spans(extractions) do
      {:ok, spans} -> {:ok, {text, spans}}
      {:error, _} = error -> error
    end
  end

  def from_map(_), do: {:error, :invalid_data}

  @doc """
  Saves a list of extraction results to a JSONL file.

  Each element is a `{source, spans}` tuple.
  """
  @spec save_jsonl([{String.t(), [Span.t()]}], Path.t()) :: :ok | {:error, File.posix()}
  def save_jsonl(results, path) do
    lines =
      Enum.map(results, fn {source, spans} ->
        [source |> to_map(spans) |> Jason.encode_to_iodata!(), "\n"]
      end)

    File.write(path, lines)
  end

  @doc """
  Loads extraction results from a JSONL file.
  """
  @spec load_jsonl(Path.t()) ::
          {:ok, [{String.t(), [Span.t()]}]} | {:error, File.posix() | :invalid_data}
  def load_jsonl(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce_while([], &parse_jsonl_line/2)
        |> collected()

      {:error, _} = error ->
        error
    end
  end

  defp parse_jsonl_line(line, acc) do
    with {:ok, map} <- Jason.decode(line),
         {:ok, result} <- from_map(map) do
      {:cont, [result | acc]}
    else
      {:error, _} -> {:halt, {:error, :invalid_data}}
    end
  end

  defp usage_to_map(nil), do: nil

  defp usage_to_map(usage) do
    %{"input_tokens" => usage.input_tokens, "output_tokens" => usage.output_tokens}
  end

  defp usage_from_map(nil), do: {:ok, nil}

  defp usage_from_map(%{"input_tokens" => input, "output_tokens" => output})
       when is_integer(input) and is_integer(output) do
    {:ok, %{input_tokens: input, output_tokens: output}}
  end

  defp usage_from_map(_), do: {:error, :invalid_data}

  defp map_chunk_errors(errors) do
    errors
    |> Enum.reduce_while([], fn map, acc ->
      case map_to_chunk_error(map) do
        {:ok, error} -> {:cont, [error | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> collected()
  end

  defp map_to_chunk_error(%{
         "byte_start" => byte_start,
         "byte_end" => byte_end,
         "reason" => reason
       })
       when is_integer(byte_start) and byte_start >= 0 and is_integer(byte_end) and
              byte_end >= 0 and is_binary(reason) do
    {:ok, %ChunkError{byte_start: byte_start, byte_end: byte_end, reason: reason}}
  end

  defp map_to_chunk_error(_), do: {:error, :invalid_data}

  defp map_spans(extractions) do
    extractions
    |> Enum.reduce_while([], fn map, acc ->
      case map_to_span(map) do
        {:ok, span} -> {:cont, [span | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> collected()
  end

  # Finishes a collect-or-halt fold: the accumulator comes back reversed,
  # or as the {:error, _} that halted it.
  defp collected({:error, _} = error), do: error
  defp collected(values), do: {:ok, Enum.reverse(values)}

  # class stays optional: align/3 produces class-less spans, and their
  # serialized form must round-trip.
  defp map_to_span(%{"text" => text} = map) when is_binary(text) do
    with {:ok, status} <- parse_status(map["status"]),
         :ok <- validate_optional_string(map["class"]),
         :ok <- validate_offsets(status, map["byte_start"], map["byte_end"]),
         {:ok, attributes} <- validate_attributes(map["attributes"]) do
      {:ok,
       %Span{
         class: map["class"],
         text: text,
         byte_start: map["byte_start"],
         byte_end: map["byte_end"],
         status: status,
         attributes: attributes
       }}
    end
  end

  defp map_to_span(_), do: {:error, :invalid_data}

  defp validate_optional_string(value) when is_binary(value) or is_nil(value), do: :ok
  defp validate_optional_string(_value), do: {:error, :invalid_data}

  # Enforces the Span invariant at the decode boundary: located spans carry
  # integer offsets, not_found spans carry nil — so a loaded span that passes
  # located?/1 is safe for offset arithmetic.
  defp validate_offsets(:not_found, nil, nil), do: :ok

  defp validate_offsets(status, byte_start, byte_end)
       when status in [:exact, :fuzzy] and is_integer(byte_start) and byte_start >= 0 and
              is_integer(byte_end) and byte_end >= 0,
       do: :ok

  defp validate_offsets(_status, _byte_start, _byte_end), do: {:error, :invalid_data}

  defp validate_attributes(nil), do: {:ok, %{}}
  defp validate_attributes(attributes) when is_map(attributes), do: {:ok, attributes}
  defp validate_attributes(_attributes), do: {:error, :invalid_data}

  defp parse_status("exact"), do: {:ok, :exact}
  defp parse_status("fuzzy"), do: {:ok, :fuzzy}
  defp parse_status("not_found"), do: {:ok, :not_found}
  defp parse_status(_), do: {:error, :invalid_data}
end
