defmodule LangExtract.Alignment.SpanTest do
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.Span

  doctest Span

  test "located?/1 is true for both grounded statuses, false for not_found" do
    assert Span.located?(%Span{text: "x", status: :exact, byte_start: 0, byte_end: 1})
    assert Span.located?(%Span{text: "x", status: :fuzzy, byte_start: 0, byte_end: 1})
    refute Span.located?(%Span{text: "x", status: :not_found})
  end
end
