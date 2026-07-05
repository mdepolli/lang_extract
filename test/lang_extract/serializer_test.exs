defmodule LangExtract.SerializerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.Span
  alias LangExtract.Serializer

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
      result = Serializer.to_map(@source, [@exact_span])

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
      result = Serializer.to_map(@source, [@not_found_span])

      [extraction] = result["extractions"]
      assert extraction["status"] == "not_found"
      assert extraction["byte_start"] == nil
      assert extraction["byte_end"] == nil
    end

    test "empty spans list" do
      result = Serializer.to_map(@source, [])
      assert result["extractions"] == []
    end

    test "preserves nested attributes" do
      span = %Span{@exact_span | attributes: %{"nested" => %{"deep" => true}}}
      result = Serializer.to_map(@source, [span])

      [extraction] = result["extractions"]
      assert extraction["attributes"] == %{"nested" => %{"deep" => true}}
    end
  end

  describe "span_to_map/1" do
    test "converts a single span" do
      map = Serializer.span_to_map(@exact_span)

      assert map == %{
               "class" => "animal",
               "text" => "fox",
               "byte_start" => 16,
               "byte_end" => 19,
               "status" => "exact",
               "attributes" => %{"type" => "mammal"}
             }
    end
  end

  describe "from_map/1" do
    test "round-trips with to_map" do
      original_spans = [@exact_span, @not_found_span]
      map = Serializer.to_map(@source, original_spans)

      assert {:ok, {source, spans}} = Serializer.from_map(map)
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
      assert {:error, :invalid_data} = Serializer.from_map(%{"extractions" => []})
    end

    test "returns error for missing extractions key" do
      assert {:error, :invalid_data} = Serializer.from_map(%{"text" => "hello"})
    end

    test "returns error for non-map input" do
      assert {:error, :invalid_data} = Serializer.from_map("not a map")
    end

    test "returns error for unknown status" do
      map = %{
        "text" => @source,
        "extractions" => [%{"text" => "fox", "status" => "bogus"}]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "returns error for missing status" do
      map = %{
        "text" => @source,
        "extractions" => [%{"text" => "fox"}]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "returns error for non-map extraction entry" do
      map = %{"text" => @source, "extractions" => ["not a map"]}

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "returns error for extraction entry without text" do
      map = %{
        "text" => @source,
        "extractions" => [%{"class" => "animal", "status" => "exact"}]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "returns error for non-string class" do
      map = %{
        "text" => @source,
        "extractions" => [%{"text" => "fox", "class" => 123, "status" => "exact"}]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "accepts a class-less span (align/3 round-trip)" do
      map = %{
        "text" => @source,
        "extractions" => [%{"text" => "fox", "status" => "exact"}]
      }

      assert {:ok, {@source, [span]}} = Serializer.from_map(map)
      assert span.class == nil
      assert span.text == "fox"
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

      assert :ok = Serializer.save_jsonl(results, path)
      assert {:ok, loaded} = Serializer.load_jsonl(path)

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

      assert :ok = Serializer.save_jsonl([], path)
      assert {:ok, []} = Serializer.load_jsonl(path)
    end

    test "load_jsonl on nonexistent file returns error" do
      assert {:error, :enoent} = Serializer.load_jsonl("/nonexistent/path.jsonl")
    end

    @tag :tmp_dir
    test "load_jsonl returns error for malformed status", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_status.jsonl")

      line =
        Jason.encode!(%{
          "text" => @source,
          "extractions" => [%{"text" => "fox", "status" => "almost_exact"}]
        })

      File.write!(path, line <> "\n")

      assert {:error, :invalid_data} = Serializer.load_jsonl(path)
    end

    @tag :tmp_dir
    test "load_jsonl returns error for invalid JSON line", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_json.jsonl")
      File.write!(path, "{not json}\n")

      assert {:error, :invalid_data} = Serializer.load_jsonl(path)
    end
  end
end
