defmodule LangExtract.IO do
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
  Converts a plain map back to extraction results.
  """
  @spec from_map(map()) :: {:ok, {String.t(), [Span.t()]}} | {:error, :invalid_data}
  def from_map(%{"text" => text, "extractions" => extractions})
      when is_binary(text) and is_list(extractions) do
    spans = Enum.map(extractions, &map_to_span/1)
    {:ok, {text, spans}}
  end

  def from_map(_), do: {:error, :invalid_data}

  @doc """
  Saves a list of extraction results to a JSONL file.

  Each element is a `{source, spans}` tuple.
  """
  @spec save_jsonl([{String.t(), [Span.t()]}], Path.t()) :: :ok | {:error, term()}
  def save_jsonl(results, path) do
    content =
      Enum.map_join(results, "\n", fn {source, spans} ->
        source |> to_map(spans) |> Jason.encode!()
      end)

    content = if content == "", do: "", else: content <> "\n"

    File.write(path, content)
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
    case Jason.decode(line) do
      {:ok, map} ->
        case from_map(map) do
          {:ok, result} -> {:cont, [result | acc]}
          {:error, _} = error -> {:halt, error}
        end

      {:error, _} ->
        {:halt, {:error, :invalid_data}}
    end
  end

  defp span_to_map(%Span{} = span) do
    %{
      "class" => span.class,
      "text" => span.text,
      "byte_start" => span.byte_start,
      "byte_end" => span.byte_end,
      "status" => Atom.to_string(span.status),
      "attributes" => span.attributes
    }
  end

  defp map_to_span(map) do
    %Span{
      class: map["class"],
      text: map["text"],
      byte_start: map["byte_start"],
      byte_end: map["byte_end"],
      status: String.to_existing_atom(map["status"]),
      attributes: map["attributes"] || %{}
    }
  end
end
