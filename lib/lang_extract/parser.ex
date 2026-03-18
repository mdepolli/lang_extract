defmodule LangExtract.Parser do
  @moduledoc """
  Parses canonical JSON into `%LangExtract.Extraction{}` structs.

  Expects clean JSON input — fence stripping and think-tag removal are
  handled upstream by `LangExtract.FormatHandler`. Validates each entry
  before constructing structs.
  """

  require Logger

  alias LangExtract.Extraction

  @spec parse(String.t() | map()) ::
          {:ok, [Extraction.t()]} | {:error, :invalid_json | :missing_extractions}
  def parse(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> parse_decoded(decoded)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def parse(decoded) when is_map(decoded) do
    parse_decoded(decoded)
  end

  defp parse_decoded(%{"extractions" => entries}) when is_list(entries) do
    {:ok, Enum.flat_map(entries, &parse_entry/1)}
  end

  defp parse_decoded(_), do: {:error, :missing_extractions}

  defp parse_entry(%{"class" => class, "text" => text} = entry)
       when is_binary(class) and class != "" and is_binary(text) and text != "" do
    attributes =
      case Map.get(entry, "attributes") do
        attrs when is_map(attrs) -> attrs
        _ -> %{}
      end

    [%Extraction{class: class, text: text, attributes: attributes}]
  end

  defp parse_entry(entry) do
    Logger.warning("Skipping invalid extraction entry: #{inspect(entry)}")
    []
  end
end
