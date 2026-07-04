defmodule LangExtract.Prompt.Template do
  @moduledoc """
  The extraction task definition: a plain-language description of what to
  extract, plus few-shot examples showing the expected output.

  There is no schema DSL and no fine-tuned model — the template is rendered
  into a few-shot prompt by `LangExtract.Prompt.Builder`, and the examples
  are what teach the model the class vocabulary, span granularity,
  attributes, and output format. See `LangExtract.Prompt.ExampleData` for
  what a good example pins down.

      %Template{
        description: "Extract medical conditions and medications.",
        examples: [
          %ExampleData{
            text: "Patient was diagnosed with diabetes and prescribed metformin.",
            extractions: [
              %Extraction{class: "condition", text: "diabetes"},
              %Extraction{class: "medication", text: "metformin"}
            ]
          }
        ]
      }
  """

  alias LangExtract.Prompt.ExampleData

  @type t :: %__MODULE__{
          description: String.t(),
          examples: [ExampleData.t()]
        }

  @enforce_keys [:description]
  defstruct [:description, examples: []]
end
