defmodule LangExtract.Provider do
  @moduledoc """
  Behaviour for LLM inference providers.

  Each provider implements `infer/2` which takes a prompt string and returns
  the raw LLM response. Parsing and normalization are the caller's responsibility.
  """

  @callback infer(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
