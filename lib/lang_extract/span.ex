defmodule LangExtract.Span do
  @moduledoc """
  An aligned extraction with its byte position in the source text.
  """

  @type status :: :exact | :fuzzy | :not_found

  @type t :: %__MODULE__{
          text: String.t(),
          byte_start: non_neg_integer() | nil,
          byte_end: non_neg_integer() | nil,
          status: status()
        }

  @enforce_keys [:text, :status]
  defstruct [:text, :byte_start, :byte_end, :status]
end
