defmodule LangExtract.Template do
  @moduledoc """
  The extraction task definition: a plain-language description of what to
  extract, plus few-shot examples showing the expected output.

  There is no schema DSL and no fine-tuned model — the template is rendered
  into a few-shot prompt by `LangExtract.Prompt.Builder`, and the examples
  are what teach the model the class vocabulary, span granularity,
  attributes, and output format.

  Build templates with `LangExtract.template/2`, which accepts plain maps
  for examples (string or atom keys, so JSON-loaded task definitions work
  verbatim) and validates them against the production aligner, raising on
  malformed or misaligned input. The struct is public for pattern
  matching and introspection.
  """

  alias LangExtract.Extraction

  defmodule Example do
    @moduledoc """
    A single few-shot example: a sample `text` paired with the extractions
    expected from it.

    The extractions are the answer key for the sample text. They pin down
    everything the template description leaves open: the class vocabulary,
    the span granularity, which attributes to attach, and the output shape
    itself — the class name becomes the JSON key in the model's reply.

    Each extraction's `text` must appear verbatim in this example's `text`:
    examples double as alignment ground truth, and `LangExtract.template/2`
    checks this at construction.
    """

    @type t :: %__MODULE__{
            text: String.t(),
            extractions: [Extraction.t()]
          }

    @enforce_keys [:text]
    defstruct [:text, extractions: []]
  end

  @type t :: %__MODULE__{
          description: String.t(),
          examples: [Example.t()]
        }

  @enforce_keys [:description]
  defstruct [:description, examples: []]
end
