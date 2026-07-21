defmodule LangExtract.SerializerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Serializer
  alias LangExtract.Span

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

  describe "result_to_map/2 and result_from_map/1" do
    alias LangExtract.ChunkError
    alias LangExtract.Result

    @chunk_error %ChunkError{
      byte_start: 0,
      byte_end: 1000,
      reason: {:task_exit, :timeout}
    }

    test "round-trips a full result: spans, errors, and usage" do
      result = %Result{
        spans: [@exact_span],
        errors: [@chunk_error],
        usage: %{input_tokens: 120, output_tokens: 45}
      }

      map = Serializer.result_to_map(@source, result)

      assert map["text"] == @source
      assert [%{"text" => "fox"}] = map["extractions"]
      assert map["usage"] == %{"input_tokens" => 120, "output_tokens" => 45}

      assert {:ok, {@source, loaded}} = Serializer.result_from_map(map)
      assert loaded.spans == [@exact_span]
      assert loaded.usage == %{input_tokens: 120, output_tokens: 45}
      assert [%ChunkError{byte_start: 0, byte_end: 1000}] = loaded.errors
    end

    test "known reason shapes serialize as tagged maps and load matchably" do
      errors = [
        %ChunkError{byte_start: 0, byte_end: 10, reason: {:task_exit, :timeout}},
        %ChunkError{byte_start: 10, byte_end: 20, reason: {:invalid_format, "not json"}},
        %ChunkError{byte_start: 20, byte_end: 30, reason: {:rate_limited, 3000}},
        %ChunkError{
          byte_start: 30,
          byte_end: 40,
          reason: {:api_error, 500, %{"error" => "boom"}}
        },
        %ChunkError{byte_start: 40, byte_end: 50, reason: :unauthorized}
      ]

      map = Serializer.result_to_map(@source, %Result{spans: [], errors: errors, usage: nil})

      assert [
               %{"reason" => %{"tag" => "task_exit", "detail" => "timeout"}},
               %{"reason" => %{"tag" => "invalid_format", "detail" => "not json"}},
               %{"reason" => %{"tag" => "rate_limited", "retry_after" => 3000}},
               %{"reason" => %{"tag" => "api_error", "status" => 500, "detail" => detail}},
               %{"reason" => %{"tag" => "unauthorized"}}
             ] = map["errors"]

      assert detail =~ "boom"
      assert {:ok, _json} = Jason.encode(map)

      # Loaded reasons keep their outer shape, so the same patterns match
      # live and loaded errors; payloads come back as strings where the
      # original term wasn't one.
      assert {:ok, {_source, loaded}} = Serializer.result_from_map(map)

      assert [
               %ChunkError{reason: {:task_exit, "timeout"}},
               %ChunkError{reason: {:invalid_format, "not json"}},
               %ChunkError{reason: {:rate_limited, 3000}},
               %ChunkError{reason: {:api_error, 500, _body}},
               %ChunkError{reason: :unauthorized}
             ] = loaded.errors
    end

    test "open reason terms fall back to tag other and load as the detail string" do
      reason = {:custom_provider_reason, :weird, [1, 2]}
      error = %ChunkError{byte_start: 0, byte_end: 5, reason: reason}

      map = Serializer.result_to_map(@source, %Result{spans: [], errors: [error], usage: nil})

      assert [%{"reason" => %{"tag" => "other", "detail" => detail}}] = map["errors"]
      assert detail == inspect(reason)
      assert {:ok, _json} = Jason.encode(map)

      assert {:ok, {_source, loaded}} = Serializer.result_from_map(map)
      assert [%ChunkError{reason: ^detail}] = loaded.errors
    end

    test "re-serializing a loaded result is stable" do
      errors = [
        %ChunkError{byte_start: 0, byte_end: 5, reason: {:custom_provider_reason, :weird}},
        %ChunkError{
          byte_start: 5,
          byte_end: 10,
          reason: {:request_error, %RuntimeError{message: "boom"}}
        }
      ]

      result = %Result{spans: [], errors: errors, usage: nil}

      load = fn map ->
        json = Jason.encode!(map)
        assert {:ok, {_source, loaded}} = Serializer.result_from_map(Jason.decode!(json))
        loaded
      end

      first = load.(Serializer.result_to_map(@source, result))
      second = load.(Serializer.result_to_map(@source, first))

      assert second.errors == first.errors

      assert [
               %ChunkError{reason: "{:custom_provider_reason, :weird}"},
               %ChunkError{reason: {:request_error, "boom"}}
             ] = second.errors
    end

    test "string reasons from pre-tagged files still load" do
      map = %{
        "text" => @source,
        "extractions" => [],
        "errors" => [
          %{"byte_start" => 0, "byte_end" => 5, "reason" => "{:task_exit, :timeout}"}
        ]
      }

      assert {:ok, {_source, loaded}} = Serializer.result_from_map(map)
      assert [%ChunkError{reason: "{:task_exit, :timeout}"}] = loaded.errors
    end

    test "malformed tagged reasons are rejected" do
      for bad <- [
            %{"tag" => "task_exit"},
            %{"tag" => "frobnicate", "detail" => "x"},
            %{"tag" => 42, "detail" => "x"},
            %{"tag" => "rate_limited", "retry_after" => "soon"},
            %{"tag" => "api_error", "status" => "500", "detail" => "x"},
            %{"detail" => "no tag"}
          ] do
        map = %{
          "text" => @source,
          "extractions" => [],
          "errors" => [%{"byte_start" => 0, "byte_end" => 5, "reason" => bad}]
        }

        assert {:error, :invalid_data} = Serializer.result_from_map(map),
               "expected rejection of #{inspect(bad)}"
      end
    end

    test "nil usage round-trips as nil" do
      result = %Result{spans: [], errors: [], usage: nil}

      map = Serializer.result_to_map(@source, result)
      assert map["usage"] == nil

      assert {:ok, {@source, %Result{usage: nil, spans: [], errors: []}}} =
               Serializer.result_from_map(map)
    end

    test "round-trips a not_found span through the full result" do
      result = %Result{spans: [@exact_span, @not_found_span], errors: [], usage: nil}

      map = Serializer.result_to_map(@source, result)

      assert {:ok, {@source, loaded}} = Serializer.result_from_map(map)
      assert loaded.spans == [@exact_span, @not_found_span]
    end

    test "result_from_map rejects invalid shapes" do
      valid = Serializer.result_to_map(@source, %Result{spans: [], errors: [], usage: nil})

      assert {:error, :invalid_data} = Serializer.result_from_map(Map.delete(valid, "text"))

      assert {:error, :invalid_data} =
               Serializer.result_from_map(Map.delete(valid, "extractions"))

      assert {:error, :invalid_data} = Serializer.result_from_map(Map.delete(valid, "errors"))
      assert {:error, :invalid_data} = Serializer.result_from_map(%{valid | "errors" => "nope"})
      assert {:error, :invalid_data} = Serializer.result_from_map(%{valid | "usage" => "nope"})

      assert {:error, :invalid_data} =
               Serializer.result_from_map(%{valid | "errors" => [%{"reason" => :not_a_string}]})

      assert {:error, :invalid_data} = Serializer.result_from_map("nope")
    end

    test "result_from_map rejects chunk errors with malformed byte offsets" do
      valid = Serializer.result_to_map(@source, %Result{spans: [], errors: [], usage: nil})
      error = %{"byte_start" => 0, "byte_end" => 1000, "reason" => "boom"}

      for bad <- [
            %{error | "byte_start" => "0"},
            %{error | "byte_end" => nil},
            %{error | "byte_start" => -1}
          ] do
        assert {:error, :invalid_data} =
                 Serializer.result_from_map(%{valid | "errors" => [bad]})
      end
    end
  end

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

    test "round-trips lesser and fuzzy spans distinctly" do
      map = %{
        "text" => @source,
        "extractions" => [
          %{
            "text" => "quick brown dog",
            "status" => "lesser",
            "byte_start" => 4,
            "byte_end" => 15
          },
          %{"text" => "foxes", "status" => "fuzzy", "byte_start" => 16, "byte_end" => 19}
        ]
      }

      assert {:ok, {@source, [lesser, fuzzy]}} = Serializer.from_map(map)
      assert lesser.status == :lesser
      assert fuzzy.status == :fuzzy

      assert %{"status" => "lesser"} = Serializer.span_to_map(lesser)
      assert %{"status" => "fuzzy"} = Serializer.span_to_map(fuzzy)
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

    test "returns error for non-integer byte offsets on a located span" do
      map = %{
        "text" => @source,
        "extractions" => [
          %{"text" => "fox", "status" => "exact", "byte_start" => "16", "byte_end" => 19}
        ]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "returns error for a located span with missing byte offsets" do
      map = %{
        "text" => @source,
        "extractions" => [%{"text" => "fox", "status" => "fuzzy"}]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "returns error for a not_found span carrying byte offsets" do
      map = %{
        "text" => @source,
        "extractions" => [
          %{"text" => "unicorn", "status" => "not_found", "byte_start" => 0, "byte_end" => 7}
        ]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "returns error for non-map attributes" do
      map = %{
        "text" => @source,
        "extractions" => [
          %{
            "text" => "fox",
            "status" => "exact",
            "byte_start" => 16,
            "byte_end" => 19,
            "attributes" => "nope"
          }
        ]
      }

      assert {:error, :invalid_data} = Serializer.from_map(map)
    end

    test "accepts a class-less span (align/3 round-trip)" do
      map = %{
        "text" => @source,
        "extractions" => [
          %{"text" => "fox", "status" => "exact", "byte_start" => 16, "byte_end" => 19}
        ]
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
    test "loaded strings do not retain the whole file binary", %{tmp_dir: tmp_dir} do
      # A span text decoded as a sub-binary would pin the entire file in
      # memory for as long as any loaded span lives — referenced_byte_size
      # exposes the size of the parent binary a sub-binary holds onto.
      # The text must be ≥ 64 bytes: the VM copies smaller matched
      # segments to the heap, so only larger strings hit the pinning path.
      big_source = String.duplicate("filler sentence goes here. ", 10_000)
      text = String.duplicate("a grounded extraction span text ", 3)
      span = %Span{text: text, status: :exact, byte_start: 0, byte_end: byte_size(text)}
      path = Path.join(tmp_dir, "retention.jsonl")

      assert :ok = Serializer.save_jsonl([{big_source, [span]}], path)
      assert {:ok, [{_source, [loaded]}]} = Serializer.load_jsonl(path)

      assert :binary.referenced_byte_size(loaded.text) < 1024
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
