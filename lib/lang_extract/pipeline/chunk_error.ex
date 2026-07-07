defmodule LangExtract.Pipeline.ChunkError do
  @moduledoc """
  A failed chunk with its byte position in the source and error reason.
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
