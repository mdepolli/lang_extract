defmodule LangExtract.Client do
  @moduledoc """
  A configured LLM client for extraction.

  Created via `LangExtract.new/2`. Holds the provider module and its options.
  """

  @type t :: %__MODULE__{
          provider: module(),
          options: keyword()
        }

  @enforce_keys [:provider]
  defstruct [:provider, options: []]
end
