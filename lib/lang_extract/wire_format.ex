defmodule LangExtract.WireFormat do
  @moduledoc """
  Port between external LLM format and internal domain.

  Serializes `%Extraction{}` structs to fenced dynamic-key JSON for prompts
  (matching upstream langextract's default — decided by the 2026-07-05
  format A/B, see benchmark/decisions/), and normalizes raw LLM output
  back to canonical format for the parser. Decoding is JSON-only (since
  0.7.0; the YAML tolerance path and its repair machinery were removed
  once JSON became the wire format).

  Both directions of the wire format live here on purpose — they share the
  dynamic-key `_attributes` contract. `Prompt.Builder` uses the encode half;
  `Pipeline` uses the decode half.
  """

  alias LangExtract.Extraction

  @attribute_suffix "_attributes"

  @spec format_extractions([Extraction.t()]) :: String.t()
  def format_extractions(extractions) do
    items = Enum.map(extractions, &serialize_extraction/1)
    json = Jason.encode!(%{"extractions" => items}, pretty: true)
    "```json\n#{json}\n```"
  end

  defp serialize_extraction(%Extraction{class: class, text: text, attributes: attributes}) do
    %{class => text, "#{class}#{@attribute_suffix}" => attributes}
  end

  @spec normalize(String.t()) :: {:ok, map()} | {:error, {:invalid_format, String.t()}}
  def normalize(raw) when is_binary(raw) do
    with {:ok, decoded} <- parse_json(raw),
         {:ok, document} <- check_document(decoded) do
      {:ok, normalize_extractions(document)}
    else
      :error -> {:error, {:invalid_format, raw}}
    end
  end

  # The sanitizers are regexes over the whole reply with no JSON-string
  # awareness, so running them unconditionally corrupts payloads whose
  # *content* carries fences or think tags — which the verbatim-span
  # instruction makes expected. Candidates are tried in mutilation order:
  # the raw reply untouched, then fence extraction (greedy first, so an
  # inner fence inside a string cannot close the payload early; lazy as
  # fallback), then the same over the think-stripped reply. First JSON
  # parse wins.
  defp parse_json(raw) do
    stripped = strip_think_tags(raw)

    [
      String.trim(raw),
      strip_fences_greedy(raw),
      strip_fences(raw),
      stripped,
      strip_fences_greedy(stripped),
      strip_fences(stripped)
    ]
    |> Enum.uniq()
    |> Enum.find_value(:error, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> nil
      end
    end)
  end

  # Any JSON object is a valid document — one without an "extractions"
  # key (including the empty object) is Parser's :missing_extractions,
  # one taxonomy for one semantic condition. Non-objects are
  # :invalid_format.
  defp check_document(%{} = decoded), do: {:ok, decoded}
  defp check_document(_decoded), do: :error

  defp normalize_extractions(%{"extractions" => entries} = document) when is_list(entries) do
    %{document | "extractions" => Enum.flat_map(entries, &normalize_entry/1)}
  end

  defp normalize_extractions(document), do: document

  @think_pattern ~r/<think>.*?(?:<\/think>|$)/s
  @fence_pattern ~r/```(?:json|yaml)?\s*(.*?)\s*```/s
  @fence_pattern_greedy ~r/```(?:json|yaml)?\s*(.*)\s*```/s

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

  defp strip_fences_greedy(raw) do
    case Regex.run(@fence_pattern_greedy, raw) do
      [_, content] -> content
      _ -> raw
    end
  end

  # Entries carrying canonical marker keys pass through untouched: a
  # complete pair is already canonical; a lone "class"/"text" is a
  # malformed echo of the canonical schema for Parser to skip — never a
  # dynamic-key group whose key names should become data
  # (class: "class", text: "drug"). This reserves "class" and "text" as
  # dynamic class names, a deliberate divergence from upstream.
  defp normalize_entry(entry) when is_map_key(entry, "class") or is_map_key(entry, "text"),
    do: [entry]

  # One canonical entry per class key, like upstream's extract loop — a
  # merged multi-key group is a classic dynamic-key model failure whose
  # extractions all survive there. Upstream keeps JSON insertion order via
  # dict; a decoded map cannot, so keys expand sorted for determinism.
  defp normalize_entry(entry) when is_map(entry) do
    all_keys = Map.keys(entry)

    {attr_keys, class_keys} =
      Enum.split_with(all_keys, &String.ends_with?(&1, @attribute_suffix))

    class_set = MapSet.new(class_keys)

    unmatched_attr_keys =
      Enum.reject(attr_keys, fn ak ->
        MapSet.member?(class_set, String.replace_suffix(ak, @attribute_suffix, ""))
      end)

    case Enum.sort(class_keys ++ unmatched_attr_keys) do
      [] -> [entry]
      effective_class_keys -> Enum.map(effective_class_keys, &canonical_entry(entry, &1))
    end
  end

  defp normalize_entry(entry), do: [entry]

  defp canonical_entry(entry, class_key) do
    attr_key = class_key <> @attribute_suffix

    attributes =
      case entry do
        %{^attr_key => attrs} when is_map(attrs) -> attrs
        _ -> %{}
      end

    %{
      "class" => class_key,
      "text" => coerce_text(Map.get(entry, class_key)),
      "attributes" => attributes
    }
  end

  # Upstream coerces int/float extraction values via str(); anything else
  # raises there but stays as-is here for Parser's per-entry skip-and-log.
  defp coerce_text(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp coerce_text(value), do: value
end
