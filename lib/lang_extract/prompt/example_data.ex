defmodule LangExtract.Prompt.ExampleData do
  @moduledoc """
  A single few-shot example: a sample `text` paired with the extractions
  expected from it.

  The extractions are the answer key for the sample text. They pin down
  everything the template description leaves open: the class vocabulary,
  the span granularity, which attributes to attach, and the output shape
  itself — the class name becomes the YAML key in the model's reply.

  Each extraction's `text` must appear verbatim in this example's `text`:
  examples double as alignment ground truth, and
  `LangExtract.Prompt.Validator` checks this before any tokens are spent.
  """

  alias LangExtract.Extraction

  @type t :: %__MODULE__{
          text: String.t(),
          extractions: [Extraction.t()]
        }

  @enforce_keys [:text]
  defstruct [:text, extractions: []]
end
