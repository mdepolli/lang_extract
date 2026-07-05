defmodule LangExtract.Pipeline.ChunkResult do
  @moduledoc """
  A successfully processed chunk: its byte range in the source and the
  spans extracted from it.

  The per-chunk success unit yielded by `LangExtract.stream/4`, sibling of
  `LangExtract.Pipeline.ChunkError`. Span byte offsets are already adjusted
  to the original document, not the chunk.
  """

  alias LangExtract.Alignment.Span

  @type t :: %__MODULE__{
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer(),
          spans: [Span.t()]
        }

  @enforce_keys [:byte_start, :byte_end, :spans]
  defstruct [:byte_start, :byte_end, :spans]
end
