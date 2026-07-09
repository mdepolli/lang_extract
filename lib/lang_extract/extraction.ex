defmodule LangExtract.Extraction do
  @moduledoc """
  A single extraction: an entity class, its verbatim source text, and
  arbitrary attributes.

  Appears on both sides of the LLM exchange: as expected output inside
  few-shot examples (`LangExtract.Template.Example`) and as parsed output
  from the model's reply. Positional information is added later by the
  aligner on `%LangExtract.Span{}`.
  """

  @type t :: %__MODULE__{
          class: String.t(),
          text: String.t(),
          attributes: map()
        }

  @enforce_keys [:class, :text]
  defstruct [:class, :text, attributes: %{}]
end
