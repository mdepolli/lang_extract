defmodule LangExtract.Extraction do
  @moduledoc """
  A single extraction from LLM output.

  Contains the entity class, verbatim source text, and arbitrary attributes.
  Positional information is added later by the aligner on `%LangExtract.Span{}`.
  """

  @type t :: %__MODULE__{
          class: String.t(),
          text: String.t(),
          attributes: map()
        }

  @enforce_keys [:class, :text]
  defstruct [:class, :text, attributes: %{}]
end
