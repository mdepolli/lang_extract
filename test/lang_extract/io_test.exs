defmodule LangExtract.IOTest do
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.Span
  alias LangExtract.IO, as: LIO

  @exact_span %Span{
    text: "fox",
    byte_start: 16,
    byte_end: 19,
    status: :exact,
    class: "animal",
    attributes: %{"type" => "mammal"}
  }

  @not_found_span %Span{
    text: "unicorn",
    byte_start: nil,
    byte_end: nil,
    status: :not_found,
    class: "animal",
    attributes: %{}
  }

  @source "the quick brown fox"

  describe "to_map/2" do
    test "converts spans to plain map" do
      result = LIO.to_map(@source, [@exact_span])

      assert result["text"] == @source
      assert [extraction] = result["extractions"]
      assert extraction["class"] == "animal"
      assert extraction["text"] == "fox"
      assert extraction["byte_start"] == 16
      assert extraction["byte_end"] == 19
      assert extraction["status"] == "exact"
      assert extraction["attributes"] == %{"type" => "mammal"}
    end

    test "not_found span has nil byte offsets" do
      result = LIO.to_map(@source, [@not_found_span])

      [extraction] = result["extractions"]
      assert extraction["status"] == "not_found"
      assert extraction["byte_start"] == nil
      assert extraction["byte_end"] == nil
    end

    test "empty spans list" do
      result = LIO.to_map(@source, [])
      assert result["extractions"] == []
    end

    test "preserves nested attributes" do
      span = %Span{@exact_span | attributes: %{"nested" => %{"deep" => true}}}
      result = LIO.to_map(@source, [span])

      [extraction] = result["extractions"]
      assert extraction["attributes"] == %{"nested" => %{"deep" => true}}
    end
  end

  describe "from_map/1" do
    test "round-trips with to_map" do
      original_spans = [@exact_span, @not_found_span]
      map = LIO.to_map(@source, original_spans)

      assert {:ok, {source, spans}} = LIO.from_map(map)
      assert source == @source
      assert length(spans) == 2

      [exact, not_found] = spans
      assert exact.text == "fox"
      assert exact.status == :exact
      assert exact.byte_start == 16
      assert exact.attributes == %{"type" => "mammal"}

      assert not_found.status == :not_found
      assert not_found.byte_start == nil
    end

    test "returns error for missing text key" do
      assert {:error, :invalid_data} = LIO.from_map(%{"extractions" => []})
    end

    test "returns error for missing extractions key" do
      assert {:error, :invalid_data} = LIO.from_map(%{"text" => "hello"})
    end

    test "returns error for non-map input" do
      assert {:error, :invalid_data} = LIO.from_map("not a map")
    end
  end

  describe "save_jsonl/2 and load_jsonl/1" do
    @tag :tmp_dir
    test "round-trips multiple results", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.jsonl")

      results = [
        {@source, [@exact_span]},
        {"another text", [@not_found_span]}
      ]

      assert :ok = LIO.save_jsonl(results, path)
      assert {:ok, loaded} = LIO.load_jsonl(path)

      assert length(loaded) == 2

      [{source1, spans1}, {source2, spans2}] = loaded
      assert source1 == @source
      assert hd(spans1).text == "fox"
      assert source2 == "another text"
      assert hd(spans2).status == :not_found
    end

    @tag :tmp_dir
    test "empty results list produces empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.jsonl")

      assert :ok = LIO.save_jsonl([], path)
      assert {:ok, []} = LIO.load_jsonl(path)
    end

    test "load_jsonl on nonexistent file returns error" do
      assert {:error, :enoent} = LIO.load_jsonl("/nonexistent/path.jsonl")
    end
  end
end
