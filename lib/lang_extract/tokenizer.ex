defmodule LangExtract.Tokenizer do
  @moduledoc """
  Regex-based tokenizer that splits text into tokens with byte offsets.

  Whitespace tokens are preserved for continuous offset mapping.
  No text normalization is applied.
  """

  alias LangExtract.Token

  @token_pattern ~r/\p{L}[\p{L}\p{M}\x{2019}'\-]*|\d[\d.,]*|[^\s]|\s+/u

  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(text) when is_binary(text) do
    @token_pattern
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{byte_start, length}] ->
      byte_end = byte_start + length
      token_text = binary_part(text, byte_start, length)

      %Token{
        text: token_text,
        type: classify(token_text),
        byte_start: byte_start,
        byte_end: byte_end
      }
    end)
  end

  defp classify(text) do
    cond do
      Regex.match?(~r/^\p{L}/u, text) -> :word
      Regex.match?(~r/^\d/, text) -> :number
      Regex.match?(~r/^\s/, text) -> :whitespace
      true -> :punctuation
    end
  end
end
