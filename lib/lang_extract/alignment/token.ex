defmodule LangExtract.Alignment.Token do
  @moduledoc """
  A token with its byte position in the source text.

  Offsets are byte positions in the UTF-8 binary, matching `Regex.scan/3`
  with `return: :index` and consumable by `binary_part/3`.
  """

  @type token_type :: :word | :number | :punctuation | :whitespace

  @type t :: %__MODULE__{
          text: String.t(),
          type: token_type(),
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer()
        }

  @enforce_keys [:text, :type, :byte_start, :byte_end]
  defstruct [:text, :type, :byte_start, :byte_end]
end
