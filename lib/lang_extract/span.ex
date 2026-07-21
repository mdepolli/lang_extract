defmodule LangExtract.Span do
  @moduledoc """
  An aligned extraction with its byte position in the source text.

  `byte_start` and `byte_end` are `nil` when `status` is `:not_found` —
  the aligner refused to guess rather than ground the extraction at wrong
  offsets. Guard offset arithmetic with `located?/1`.

  Statuses, from strongest to weakest grounding:

    * `:exact` — the extraction's tokens appear verbatim and contiguously
      in the source
    * `:lesser` — only the extraction's opening run grounds (upstream's
      `MATCH_LESSER`): the model over-extracted or stitched fragments, and
      the span covers the prefix that exists in the source
    * `:fuzzy` — an order-preserving subsequence match over lightly
      stemmed tokens; the span covers the matched region
    * `:not_found` — no acceptable grounding

  Only `text` is grounded: `attributes` are free-form model output with
  no byte anchoring, so treat them as untrusted before use in any
  sensitive sink.
  """

  @type status :: :exact | :lesser | :fuzzy | :not_found

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
  Whether the aligner grounded this span — `status` is `:exact`,
  `:lesser`, or `:fuzzy`, so the byte offsets are present.

  The filtering idiom for consumers doing offset arithmetic:

      iex> spans = [
      ...>   %LangExtract.Span{text: "found", status: :exact, byte_start: 0, byte_end: 5},
      ...>   %LangExtract.Span{text: "lost", status: :not_found}
      ...> ]
      iex> Enum.filter(spans, &LangExtract.Span.located?/1)
      [%LangExtract.Span{text: "found", status: :exact, byte_start: 0, byte_end: 5}]

  """
  @spec located?(t()) :: boolean()
  def located?(%__MODULE__{status: status}), do: status in [:exact, :lesser, :fuzzy]
end
