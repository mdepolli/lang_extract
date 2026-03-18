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
    %{class => text, "#{class}#{@attribute_suffix}" => attributes || %{}}
  end
end
