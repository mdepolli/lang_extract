defmodule Mix.Tasks.Benchmark.RunTest do
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.Span
  alias LangExtract.Pipeline.ChunkError
  alias Mix.Tasks.Benchmark.Run

  @span %Span{
    text: "fox",
    byte_start: 16,
    byte_end: 19,
    status: :exact,
    class: "animal",
    attributes: %{}
  }

  describe "document_result/4" do
    test "clean success has empty errors list and timing" do
      result = Run.document_result("slug", "dialogue", {:ok, {[@span], []}}, 1200)

      assert result["source"] == "slug"
      assert result["task"] == "dialogue"
      assert result["library"] == "elixir"
      assert [%{"text" => "fox", "status" => "exact"}] = result["extractions"]
      assert result["timing"] == %{"total_ms" => 1200}
      assert result["errors"] == []
    end

    test "partial success carries chunk errors alongside extractions" do
      error = %ChunkError{byte_start: 0, byte_end: 1000, reason: :rate_limited}
      result = Run.document_result("slug", "ner", {:ok, {[@span], [error]}}, 900)

      assert length(result["extractions"]) == 1
      assert result["timing"] == %{"total_ms" => 900}

      assert result["errors"] == [
               %{"byte_start" => 0, "byte_end" => 1000, "reason" => ":rate_limited"}
             ]
    end

    test "total failure has null timing and a single null-offset error" do
      result = Run.document_result("slug", "ner", {:error, :timeout}, 500)

      assert result["extractions"] == []
      assert result["timing"] == nil

      assert result["errors"] == [
               %{"byte_start" => nil, "byte_end" => nil, "reason" => ":timeout"}
             ]
    end

    test "result encodes to JSON" do
      assert {:ok, _} =
               "slug"
               |> Run.document_result("dialogue", {:ok, {[@span], []}}, 1)
               |> Jason.encode()
    end
  end
end
