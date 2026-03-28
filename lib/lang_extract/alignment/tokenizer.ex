defmodule LangExtract.Alignment.Tokenizer do
  @moduledoc """
  Regex-based tokenizer that splits text into tokens with byte offsets.

  Whitespace tokens are preserved for continuous offset mapping.
  No text normalization is applied.
  """

  alias LangExtract.Alignment.Token

  @token_pattern ~r/\p{L}[\p{L}\p{M}\x{2019}'\-]*|\d[\d.,]*|[^\s]|\s+/u
  @unicode_letter ~r/^\p{L}/u

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

  # ASCII fast path — first byte < 128 is fully classified without regex.
  # Non-ASCII first byte (>= 128) falls through to Unicode regex for \p{L}.
  defp classify(<<c, _::binary>>) when c in ?A..?Z or c in ?a..?z, do: :word
  defp classify(<<c, _::binary>>) when c in ?0..?9, do: :number
  defp classify(<<c, _::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: :whitespace
  defp classify(<<c, _::binary>>) when c < 128, do: :punctuation

  defp classify(text) do
    if Regex.match?(@unicode_letter, text), do: :word, else: :punctuation
  end
end
