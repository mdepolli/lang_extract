defmodule LangExtract.Alignment.Tokenizer do
  @moduledoc """
  Regex-based tokenizer that splits text into tokens with byte offsets.

  Mirrors upstream langextract's `RegexTokenizer`: letter runs, digit
  runs, and same-symbol runs (`...` is one token, `?!` is two) — so
  `Tooke’s` tokenizes as `Tooke` · `’` · `s` and the aligner sees the
  bare name exactly as upstream does. Whitespace tokens are additionally
  preserved (upstream tracks newlines as a token flag instead) for
  continuous offset mapping and the chunker's newline rule.
  No text normalization is applied.

  Internal — no stability guarantees; see the README's "Stability"
  section. Documented because it explains how the library works, not
  because it is API.
  """

  alias LangExtract.Alignment.Token

  # Upstream: _LETTERS_PATTERN | _DIGITS_PATTERN | _SYMBOLS_PATTERN.
  # The backreference makes symbol runs same-character only.
  @token_pattern ~r/[^\W\d_]+|\d+|([^\w\s]|_)\1*|\s+/u
  @unicode_letter ~r/^\p{L}/u

  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(text) when is_binary(text) do
    @token_pattern
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{byte_start, length} | _captures] ->
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
