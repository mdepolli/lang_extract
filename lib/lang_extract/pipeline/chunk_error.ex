defmodule LangExtract.Pipeline.ChunkError do
  @moduledoc """
  A failed chunk with its byte position in the source and error reason.
  """

  @type t :: %__MODULE__{
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer(),
          reason: term()
        }

  @enforce_keys [:byte_start, :byte_end, :reason]
  defstruct [:byte_start, :byte_end, :reason]
end
