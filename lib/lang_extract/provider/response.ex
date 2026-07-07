defmodule LangExtract.Provider.Response do
  @moduledoc """
  A provider's successful inference response: the raw text plus token
  usage when the API reported it.

  The success value of `c:LangExtract.Provider.infer/2`. `usage` is `nil`
  when the response carried no usage block (some proxies and local models
  omit it); when present it carries `:input_tokens` and `:output_tokens`.
  """

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @type t :: %__MODULE__{text: String.t(), usage: usage() | nil}

  @enforce_keys [:text]
  defstruct [:text, :usage]
end
