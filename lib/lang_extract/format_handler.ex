defmodule LangExtract.FormatHandler do
  @moduledoc """
  Port between external LLM format and internal domain.

  Serializes `%Extraction{}` structs to dynamic-key JSON for prompts,
  and normalizes raw LLM output back to canonical format for the parser.
  """

  alias LangExtract.Extraction

  @attribute_suffix "_attributes"

  @spec format_extractions([Extraction.t()]) :: String.t()
  def format_extractions(extractions) do
    items = Enum.map(extractions, &serialize_extraction/1)
    payload = %{"extractions" => items}
    json = Jason.encode!(payload, pretty: true)
    "```json\n#{json}\n```"
  end

  defp serialize_extraction(%Extraction{class: class, text: text, attributes: attributes}) do
    %{class => text, "#{class}#{@attribute_suffix}" => attributes}
  end

  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_format}
  def normalize(raw) when is_binary(raw) do
    cleaned = raw |> strip_think_tags() |> strip_fences()

    case Jason.decode(cleaned) do
      {:ok, %{"extractions" => entries} = decoded} when is_list(entries) ->
        normalized = Enum.map(entries, &normalize_entry/1)
        {:ok, Jason.encode!(%{decoded | "extractions" => normalized})}

      {:ok, _} ->
        {:error, :invalid_format}

      {:error, _} ->
        {:error, :invalid_format}
    end
  end

  @think_pattern ~r/<think>.*?<\/think>/s
  @think_unclosed ~r/<think>.*/s
  @fence_pattern ~r/```(?:json)?\s*(.*?)\s*```/s

  defp strip_think_tags(raw) do
    raw
    |> String.replace(@think_pattern, "")
    |> String.replace(@think_unclosed, "")
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

    matched_attr_keys =
      Enum.filter(attr_keys, fn attr_key ->
        prefix = String.replace_suffix(attr_key, @attribute_suffix, "")
        prefix in class_keys
      end)

    unmatched_attr_keys = attr_keys -- matched_attr_keys
    effective_class_keys = class_keys ++ unmatched_attr_keys

    case effective_class_keys do
      [class_key] ->
        attr_key = "#{class_key}#{@attribute_suffix}"

        attributes = resolve_attributes(entry, attr_key, matched_attr_keys)

        %{"class" => class_key, "text" => Map.get(entry, class_key), "attributes" => attributes}

      _ ->
        entry
    end
  end

  defp normalize_entry(entry), do: entry

  defp resolve_attributes(entry, attr_key, matched_attr_keys) do
    if attr_key in matched_attr_keys do
      case Map.get(entry, attr_key) do
        attrs when is_map(attrs) -> attrs
        _ -> %{}
      end
    else
      %{}
    end
  end
end
