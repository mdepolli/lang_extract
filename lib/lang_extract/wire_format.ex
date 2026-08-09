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
  # Canonical marker keys the decode side (normalize_entry) reserves.
  @marker_keys ~w(class text)
  @think_pattern ~r/<think>.*?(?:<\/think>|$)/s
  @fence_pattern ~r/```(?:json|yaml)?\s*(.*?)\s*```/s
  @fence_pattern_greedy ~r/```(?:json|yaml)?\s*(.*)\s*```/s
  # Cap retained garbage so a max_tokens-sized non-JSON reply cannot pin
  # multi-megabyte binaries in ChunkError.reason / serialized results.
  @max_invalid_format_bytes 4_096

  @doc """
  Class names reserved by the wire contract.

  Encoding one of these as a dynamic key collides with the canonical
  `"class"`/`"text"` marker keys the decoder passes through untouched, so
  template construction rejects them up front.
  """
  @spec reserved_marker_keys() :: [String.t()]
  def reserved_marker_keys, do: @marker_keys

  @doc """
  Suffix reserved for attribute-carrier keys (`"<class>_attributes"`).

  A class name ending in it would decode as attributes for another class,
  so template construction rejects those up front as well.
  """
  @spec attribute_suffix() :: String.t()
  def attribute_suffix, do: @attribute_suffix

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
    case parse_json(raw) do
      {:ok, document} -> {:ok, normalize_extractions(document)}
      :error -> {:error, {:invalid_format, preview_raw(raw)}}
    end
  end

  # The sanitizers are regexes over the whole reply with no JSON-string
  # awareness, so running them unconditionally corrupts payloads whose
  # *content* carries fences or think tags — which the verbatim-span
  # instruction makes expected. Build candidates in mutilation order
  # (raw, each fenced block, greedy outer span, think-stripped variants),
  # decode those that Jason accepts as maps — only objects are documents;
  # non-object JSON is :invalid_format, while an object without
  # "extractions" (including {}) stays Parser's :missing_extractions —
  # and pick by richness: longer `"extractions"` list wins so an echoed
  # empty few-shot fence does not silence a later answer fence; ties keep
  # the later candidate. Residual ambiguity, accepted: richness cannot
  # tell a *non-empty* few-shot echo from a smaller (or legitimately
  # empty) real answer — the echo wins those.
  #
  # strings: :copy — same contract as Serializer.load_jsonl: decoded
  # strings ≥ 64 bytes would otherwise be sub-binaries of the LLM reply
  # and pin the whole payload for as long as any Span.text lives.
  defp parse_json(raw) do
    raw
    |> json_candidates()
    |> Enum.with_index()
    |> Enum.flat_map(fn {candidate, index} ->
      case Jason.decode(candidate, strings: :copy) do
        {:ok, decoded} when is_map(decoded) -> [{decoded, index}]
        _ -> []
      end
    end)
    |> case do
      [] ->
        :error

      decoded ->
        {best, _index} =
          Enum.max_by(decoded, fn {document, index} ->
            {extractions_score(document), index}
          end)

        {:ok, best}
    end
  end

  defp extractions_score(%{"extractions" => entries}) when is_list(entries), do: length(entries)
  defp extractions_score(_document), do: -1

  defp json_candidates(raw) do
    trimmed = String.trim(raw)
    stripped = strip_think_tags(raw)

    [trimmed, stripped]
    |> Enum.flat_map(&text_candidates/1)
    |> Enum.uniq()
  end

  # Per text layer: the full text, every fenced interior (source order),
  # then the greedy outer span (needed when an extraction string itself
  # contains ``` — non-greedy scan would close on the inner fence).
  defp text_candidates(text) do
    [text | fence_interiors(text) ++ [greedy_fence_interior(text)]]
  end

  defp fence_interiors(text) do
    @fence_pattern
    |> Regex.scan(text)
    |> Enum.map(fn [_, content] -> content end)
  end

  defp greedy_fence_interior(text) do
    case Regex.run(@fence_pattern_greedy, text) do
      [_, content] -> content
      _ -> text
    end
  end

  defp preview_raw(raw) when byte_size(raw) <= @max_invalid_format_bytes, do: raw

  defp preview_raw(raw) do
    prefix = valid_prefix(binary_part(raw, 0, @max_invalid_format_bytes))
    prefix <> "…(#{byte_size(raw)} bytes total, truncated)"
  end

  # The cut can land mid-character; trim trailing bytes one at a time
  # until the prefix is valid on its own — at most 3 steps for UTF-8
  # input, since a character is at most 4 bytes.
  defp valid_prefix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      valid_prefix(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end

  defp normalize_extractions(%{"extractions" => entries} = document) when is_list(entries) do
    %{document | "extractions" => Enum.flat_map(entries, &normalize_entry/1)}
  end

  defp normalize_extractions(document), do: document

  defp strip_think_tags(raw) do
    raw
    |> String.replace(@think_pattern, "")
    |> String.trim()
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
