defmodule LangExtract.Prompt.Template do
  @moduledoc """
  Holds the extraction task description and few-shot examples.
  """

  alias LangExtract.Prompt.ExampleData

  @type t :: %__MODULE__{
          description: String.t(),
          examples: [ExampleData.t()]
        }

  @enforce_keys [:description]
  defstruct [:description, examples: []]
end
