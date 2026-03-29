defmodule LangExtract.Parser do
  @moduledoc """
  Parses canonical extraction maps into `%LangExtract.Extraction{}` structs.

  Expects normalized maps from `LangExtract.FormatHandler`. Validates each
  entry before constructing structs.
  """

  require Logger

  alias LangExtract.Extraction

  @spec parse(map()) :: {:ok, [Extraction.t()]} | {:error, :missing_extractions}
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
