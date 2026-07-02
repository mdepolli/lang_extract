defmodule LangExtract.Chunker.Chunk do
  @moduledoc """
  A chunk of text with its byte offset in the source.
  """

  @type t :: %__MODULE__{
          text: String.t(),
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer()
        }
  @enforce_keys [:text, :byte_start, :byte_end]
  defstruct [:text, :byte_start, :byte_end]
end
