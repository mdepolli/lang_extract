defmodule LangExtract.Result do
  @moduledoc """
  A completed extraction run: document-ordered spans plus per-chunk errors.

  The success value of `LangExtract.run/4` and `LangExtract.Runner.run/4`.
  A struct rather than a positional tuple so future fields (usage, timing)
  can be added without breaking consumer matches — bind only the keys you
  need:

      {:ok, %LangExtract.Result{spans: spans, errors: errors}} =
        LangExtract.run(client, source, template)

  `spans` are in document order (by `byte_start`); `errors` carry the byte
  range of each failed chunk, also in document order. An empty `errors`
  list means every chunk extracted cleanly.
  """

  alias LangExtract.Alignment.Span
  alias LangExtract.Pipeline.ChunkError

  @type t :: %__MODULE__{spans: [Span.t()], errors: [ChunkError.t()]}

  @enforce_keys [:spans, :errors]
  defstruct [:spans, :errors]
end
