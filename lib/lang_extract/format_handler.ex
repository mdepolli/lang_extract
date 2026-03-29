defmodule LangExtract.FormatHandler do
  @moduledoc """
  Port between external LLM format and internal domain.

  Serializes `%Extraction{}` structs to dynamic-key YAML for prompts,
  and normalizes raw LLM output back to canonical format for the parser.
  """

  alias LangExtract.Extraction

  @attribute_suffix "_attributes"

  @spec format_extractions([Extraction.t()]) :: String.t()
  def format_extractions(extractions) do
    items = Enum.map(extractions, &serialize_extraction/1)
    payload = %{"extractions" => items}
    yaml = Ymlr.document!(payload)
    "```yaml\n#{yaml}```"
  end

  defp serialize_extraction(%Extraction{class: class, text: text, attributes: attributes}) do
    %{class => text, "#{class}#{@attribute_suffix}" => attributes}
  end

  @spec normalize(String.t()) :: {:ok, map()} | {:error, {:invalid_format, String.t()}}
  def normalize(raw) when is_binary(raw) do
    cleaned = raw |> strip_think_tags() |> strip_fences()

    case YamlElixir.read_from_string(cleaned) do
      {:ok, %{"extractions" => entries} = decoded} when is_list(entries) ->
        normalized = Enum.map(entries, &normalize_entry/1)
        {:ok, %{decoded | "extractions" => normalized}}

      _ ->
        {:error, {:invalid_format, raw}}
    end
  end

  @think_pattern ~r/<think>.*?(?:<\/think>|$)/s
  @fence_pattern ~r/```(?:json|yaml)?\s*(.*?)\s*```/s

  defp strip_think_tags(raw) do
    raw
    |> String.replace(@think_pattern, "")
    |> String.trim()
  end

  defp strip_fences(raw) do
    case Regex.run(@fence_pattern, raw) do
      [_, content] -> content
      _ -> raw
    end
  end

  defp normalize_entry(%{"class" => _, "text" => _} = entry), do: entry

  defp normalize_entry(entry) when is_map(entry) do
    all_keys = Map.keys(entry)

    {attr_keys, class_keys} =
      Enum.split_with(all_keys, &String.ends_with?(&1, @attribute_suffix))

    class_set = MapSet.new(class_keys)

    unmatched_attr_keys =
      Enum.reject(attr_keys, fn ak ->
        MapSet.member?(class_set, String.replace_suffix(ak, @attribute_suffix, ""))
      end)

    effective_class_keys = class_keys ++ unmatched_attr_keys

    case effective_class_keys do
      [class_key] ->
        attr_key = class_key <> @attribute_suffix

        attributes =
          case entry do
            %{^attr_key => attrs} when is_map(attrs) -> attrs
            _ -> %{}
          end

        %{"class" => class_key, "text" => Map.get(entry, class_key), "attributes" => attributes}

      _ ->
        entry
    end
  end

  defp normalize_entry(entry), do: entry
end
