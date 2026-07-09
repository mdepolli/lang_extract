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

  alias LangExtract.Chunker.Chunk

  @type t :: %__MODULE__{
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer(),
          reason: term()
        }

  @enforce_keys [:byte_start, :byte_end, :reason]
  defstruct [:byte_start, :byte_end, :reason]

  @doc "Builds an error carrying `chunk`'s byte range."
  @spec from_chunk(Chunk.t(), term()) :: t()
  def from_chunk(%Chunk{} = chunk, reason) do
    %__MODULE__{byte_start: chunk.byte_start, byte_end: chunk.byte_end, reason: reason}
  end
end
