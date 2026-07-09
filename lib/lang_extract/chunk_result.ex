defmodule LangExtract.ChunkResult do
  @moduledoc """
  A successfully processed chunk: its byte range in the source and the
  spans extracted from it.

  The per-chunk success unit yielded by `LangExtract.stream/4`, sibling of
  `LangExtract.ChunkError`. Span byte offsets are already adjusted
  to the original document, not the chunk.
  """

  alias LangExtract.Alignment.Span
  alias LangExtract.Chunker.Chunk
  alias LangExtract.Provider.Response

  @type t :: %__MODULE__{
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer(),
          spans: [Span.t()],
          usage: Response.usage() | nil
        }

  @enforce_keys [:byte_start, :byte_end, :spans]
  defstruct [:byte_start, :byte_end, :spans, :usage]

  @doc "Builds a result carrying `chunk`'s byte range and the request's usage."
  @spec from_chunk(Chunk.t(), [Span.t()], Response.usage() | nil) :: t()
  def from_chunk(%Chunk{} = chunk, spans, usage \\ nil) do
    %__MODULE__{
      byte_start: chunk.byte_start,
      byte_end: chunk.byte_end,
      spans: spans,
      usage: usage
    }
  end
end
