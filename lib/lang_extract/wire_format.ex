defmodule LangExtract.WireFormat do
  @moduledoc """
  Port between external LLM format and internal domain.

  Serializes `%Extraction{}` structs to fenced dynamic-key JSON for prompts
  (matching upstream langextract's default — decided by the 2026-07-05
  format A/B, see benchmark/BASELINE.md), and normalizes raw LLM output
  back to canonical format for the parser. The decode half is
  format-agnostic: JSON is a YAML subset, so it parses YAML responses and
  keeps the YAML repair machinery as tolerance for malformed output.

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
    cleaned = raw |> strip_think_tags() |> strip_fences()

    # Valid YAML must never be rewritten (the quoting repairs corrupt legal
    # constructs like multi-line plain scalars) — repair only on failure.
    with :error <- parse(cleaned),
         :error <- cleaned |> quote_yaml_values() |> parse() do
      {:error, {:invalid_format, raw}}
    end
  end

  defp parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"extractions" => entries} = decoded} when is_list(entries) ->
        normalized = Enum.map(entries, &normalize_entry/1)
        {:ok, %{decoded | "extractions" => normalized}}

      # Valid YAML without "extractions" key — let Parser return :missing_extractions
      {:ok, %{} = decoded} when decoded != %{} ->
        {:ok, decoded}

      _ ->
        :error
    end
  end

  @yaml_value_re ~r/^(\s+- [\w-]+: )(.+)$/m
  # Block scalar headers (|, |-, >2+, ...) introduce the indented lines that
  # follow — quoting one as a value orphans its block and breaks the parse.
  @block_scalar_re ~r/^[|>][0-9+-]{0,2}$/

  # Only reached when the document already failed to parse, so rewriting
  # aggressively is safe: fold stray plain-scalar continuation lines into
  # their value line, then requote every value from scratch.
  defp quote_yaml_values(yaml) do
    yaml
    |> join_plain_continuations()
    |> requote_values()
  end

  defp requote_values(yaml) do
    Regex.replace(@yaml_value_re, yaml, fn full, prefix, value ->
      if value =~ @block_scalar_re do
        full
      else
        prefix <> requote(value)
      end
    end)
  end

  # Strips one layer of (possibly unterminated or mis-escaped) model quoting,
  # then requotes with everything inside escaped. Sources carry smart quotes,
  # so an ASCII quote at the value boundary is model syntax, not span content.
  defp requote(value) do
    value
    |> strip_outer_quotes()
    |> String.replace("\\\"", "\"")
    |> then(&("\"" <> String.replace(&1, "\"", "\\\"") <> "\""))
  end

  defp strip_outer_quotes(value) do
    trimmed = String.trim_trailing(value)

    cond do
      byte_size(trimmed) > 1 and String.starts_with?(trimmed, "\"") and
          String.ends_with?(trimmed, "\"") ->
        binary_part(trimmed, 1, byte_size(trimmed) - 2)

      String.starts_with?(trimmed, "\"") ->
        binary_part(trimmed, 1, byte_size(trimmed) - 1)

      true ->
        trimmed
    end
  end

  @item_value_re ~r/^\s*- [\w-]+: (.+)$/
  @key_line_re ~r/^\s*(?:- )?[\w-]+:(?: |$)/

  # The model sometimes continues a plain scalar on deeper-indented lines
  # (verse dialogue); fold those into the value line so requoting covers
  # the whole scalar. Block scalar content is never touched.
  defp join_plain_continuations(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.reduce([], &join_line/2)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp join_line(line, []), do: [line]

  defp join_line(line, [prev | rest] = acc) do
    if continuation?(line, prev) do
      [prev <> " " <> String.trim(line) | rest]
    else
      [line | acc]
    end
  end

  defp continuation?(line, prev) do
    String.trim(line) != "" and
      not Regex.match?(@key_line_re, line) and
      plain_item_value?(prev)
  end

  defp plain_item_value?(prev) do
    case Regex.run(@item_value_re, prev) do
      [_, value] -> not Regex.match?(@block_scalar_re, value)
      nil -> false
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
