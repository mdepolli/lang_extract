defmodule LangExtract.Span do
  @moduledoc """
  An aligned extraction with its byte position in the source text.

  `byte_start` and `byte_end` are `nil` when `status` is `:not_found` —
  the aligner refused to guess rather than ground the extraction at wrong
  offsets. Guard offset arithmetic with `located?/1`.
  """

  @type status :: :exact | :fuzzy | :not_found

  @type t :: %__MODULE__{
          text: String.t(),
          byte_start: non_neg_integer() | nil,
          byte_end: non_neg_integer() | nil,
          status: status(),
          class: String.t() | nil,
          attributes: map()
        }

  @enforce_keys [:text, :status]
  defstruct [:text, :byte_start, :byte_end, :status, :class, attributes: %{}]

  @doc """
  Whether the aligner grounded this span — `status` is `:exact` or
  `:fuzzy`, so the byte offsets are present.

  The filtering idiom for consumers doing offset arithmetic:

      iex> spans = [
      ...>   %LangExtract.Span{text: "found", status: :exact, byte_start: 0, byte_end: 5},
      ...>   %LangExtract.Span{text: "lost", status: :not_found}
      ...> ]
      iex> Enum.filter(spans, &LangExtract.Span.located?/1)
      [%LangExtract.Span{text: "found", status: :exact, byte_start: 0, byte_end: 5}]

  """
  @spec located?(t()) :: boolean()
  def located?(%__MODULE__{status: status}), do: status in [:exact, :fuzzy]
end
