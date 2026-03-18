defmodule LangExtract.ExampleData do
  @moduledoc """
  A single few-shot example: source text and expected extractions.
  """

  alias LangExtract.Extraction

  @type t :: %__MODULE__{
          text: String.t(),
          extractions: [Extraction.t()]
        }

  @enforce_keys [:text]
  defstruct [:text, extractions: []]
end
