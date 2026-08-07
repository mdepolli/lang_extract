defmodule LangExtract.ChunkResult do
  @moduledoc """
  A successfully processed chunk: its byte range in the source and the
  spans extracted from it.

  The per-chunk success unit yielded by `LangExtract.stream/4`, sibling of
  `LangExtract.ChunkError`. Span byte offsets are already adjusted
  to the original document, not the chunk.
  """

  alias LangExtract.Provider.Response
  alias LangExtract.Span

  @type t :: %__MODULE__{
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer(),
          spans: [Span.t()],
          usage: Response.usage() | nil
        }

  @enforce_keys [:byte_start, :byte_end, :spans]
  defstruct [:byte_start, :byte_end, :spans, :usage]

  @doc """
  Builds a result for an explicit byte range and the request's usage.

  Prefer this over `from_chunk/3` when you already have the range — Core
  does not type-depend on Advanced `Chunker.Chunk`.
  """
  @spec from_range(non_neg_integer(), non_neg_integer(), [Span.t()], Response.usage() | nil) ::
          t()
  def from_range(byte_start, byte_end, spans, usage \\ nil)
      when is_integer(byte_start) and byte_start >= 0 and is_integer(byte_end) and
             byte_end >= byte_start and is_list(spans) do
    %__MODULE__{
      byte_start: byte_start,
      byte_end: byte_end,
      spans: spans,
      usage: usage
    }
  end

  @doc """
  Builds a result carrying a chunk-like map's byte range and the request's usage.

  Accepts any map with integer `:byte_start` / `:byte_end` (including
  `%LangExtract.Chunker.Chunk{}`) so Core stays free of an Advanced-tier
  type dependency.
  """
  @spec from_chunk(
          %{
            required(:byte_start) => non_neg_integer(),
            required(:byte_end) => non_neg_integer(),
            optional(any()) => any()
          },
          [Span.t()],
          Response.usage() | nil
        ) :: t()
  def from_chunk(%{byte_start: byte_start, byte_end: byte_end}, spans, usage \\ nil) do
    from_range(byte_start, byte_end, spans, usage)
  end
end
