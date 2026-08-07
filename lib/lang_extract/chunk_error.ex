defmodule LangExtract.ChunkError do
  @moduledoc """
  A failed chunk with its byte position in the source and error reason.

  `reason` is deliberately open (`t:term/0`): it funnels whatever the
  failing layer reported. Common shapes, non-exhaustive:

    * `t:LangExtract.Provider.error/0` — the LLM request failed, e.g.
      `{:rate_limited, ms}` or `:server_error` once retries are exhausted
    * `{:invalid_format, message}` or `:missing_extractions` — the LLM
      reply didn't parse
    * `{:task_exit, reason}` — the chunk task crashed or timed out
    * `:drained` — the runner shut down before the chunk started
  """

  @type t :: %__MODULE__{
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer(),
          reason: term()
        }

  @enforce_keys [:byte_start, :byte_end, :reason]
  defstruct [:byte_start, :byte_end, :reason]

  @doc """
  Builds an error for an explicit byte range.

  Prefer this over `from_chunk/2` when you already have the range — Core
  does not type-depend on Advanced `Chunker.Chunk`.
  """
  @spec from_range(non_neg_integer(), non_neg_integer(), term()) :: t()
  def from_range(byte_start, byte_end, reason)
      when is_integer(byte_start) and byte_start >= 0 and is_integer(byte_end) and
             byte_end >= byte_start do
    %__MODULE__{byte_start: byte_start, byte_end: byte_end, reason: reason}
  end

  @doc """
  Builds an error carrying a chunk-like map's byte range.

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
          term()
        ) :: t()
  def from_chunk(%{byte_start: byte_start, byte_end: byte_end}, reason) do
    from_range(byte_start, byte_end, reason)
  end
end
