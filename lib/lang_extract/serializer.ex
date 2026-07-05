defmodule LangExtract.Serializer do
  @moduledoc """
  Serialization and deserialization of extraction results.

  Converts between LangExtract structs and plain maps/JSON for storage,
  debugging, and interop with external systems.
  """

  alias LangExtract.Alignment.Span

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

  Returns `{:error, :invalid_data}` if the shape is wrong or an extraction
  has an unknown `"status"`.
  """
  @spec from_map(map()) :: {:ok, {String.t(), [Span.t()]}} | {:error, :invalid_data}
  def from_map(%{"text" => text, "extractions" => extractions})
      when is_binary(text) and is_list(extractions) do
    with {:ok, spans} <- map_spans(extractions) do
      {:ok, {text, spans}}
    end
  end

  def from_map(_), do: {:error, :invalid_data}

  @doc """
  Saves a list of extraction results to a JSONL file.

  Each element is a `{source, spans}` tuple.
  """
  @spec save_jsonl([{String.t(), [Span.t()]}], Path.t()) :: :ok | {:error, term()}
  def save_jsonl([], path), do: File.write(path, "")

  def save_jsonl(results, path) do
    content =
      Enum.map_join(results, "\n", fn {source, spans} ->
        source |> to_map(spans) |> Jason.encode!()
      end)

    File.write(path, [content, "\n"])
  end

  @doc """
  Loads extraction results from a JSONL file.
  """
  @spec load_jsonl(Path.t()) :: {:ok, [{String.t(), [Span.t()]}]} | {:error, term()}
  def load_jsonl(path) do
    with {:ok, content} <- File.read(path) do
      results =
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce_while([], &parse_jsonl_line/2)

      case results do
        {:error, _} = error -> error
        list when is_list(list) -> {:ok, Enum.reverse(list)}
      end
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

  defp map_spans(extractions) do
    spans =
      Enum.reduce_while(extractions, [], fn map, acc ->
        case map_to_span(map) do
          {:ok, span} -> {:cont, [span | acc]}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case spans do
      {:error, _} = error -> error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  # class stays optional: align/3 produces class-less spans, and their
  # serialized form must round-trip.
  defp map_to_span(%{"text" => text} = map) when is_binary(text) do
    with {:ok, status} <- parse_status(map["status"]),
         :ok <- validate_optional_string(map["class"]) do
      {:ok,
       %Span{
         class: map["class"],
         text: text,
         byte_start: map["byte_start"],
         byte_end: map["byte_end"],
         status: status,
         attributes: map["attributes"] || %{}
       }}
    end
  end

  defp map_to_span(_), do: {:error, :invalid_data}

  defp validate_optional_string(value) when is_binary(value) or is_nil(value), do: :ok
  defp validate_optional_string(_value), do: {:error, :invalid_data}

  defp parse_status("exact"), do: {:ok, :exact}
  defp parse_status("fuzzy"), do: {:ok, :fuzzy}
  defp parse_status("not_found"), do: {:ok, :not_found}
  defp parse_status(_), do: {:error, :invalid_data}
end
