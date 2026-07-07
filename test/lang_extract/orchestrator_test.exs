defmodule LangExtract.OrchestratorTest do
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.Span
  alias LangExtract.Client
  alias LangExtract.Pipeline.ChunkError
  alias LangExtract.Result
  alias LangExtract.Test.FakeAnthropic
  alias LangExtract.Test.Telemetry

  @req_options [plug: {Req.Test, __MODULE__}]

  describe "LangExtract.stream/4" do
    alias LangExtract.Pipeline.ChunkResult

    @two_chunk_source "First sentence here. Second sentence there."

    defp counting_stub(parent) do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        prompt = hd(Jason.decode!(body)["messages"])["content"]
        send(parent, {:request_made, prompt})

        # First chunk is slow, so the second completes first.
        if prompt =~ "First", do: Process.sleep(150)

        word = if prompt =~ "First", do: "First", else: "Second"
        FakeAnthropic.respond_ok(conn, [%{"word" => word}])
      end)
    end

    test "is lazy: building the stream makes no requests" do
      counting_stub(self())

      stream =
        LangExtract.stream(claude_client(), @two_chunk_source, template(), max_chunk_chars: 25)

      refute_receive {:request_made, _}, 100

      assert length(Enum.to_list(stream)) == 2
      assert_receive {:request_made, _}
    end

    test "yields events in completion order with byte ranges" do
      counting_stub(self())

      events =
        claude_client()
        |> LangExtract.stream(@two_chunk_source, template(),
          max_chunk_chars: 25,
          max_concurrency: 2
        )
        |> Enum.to_list()

      # The slow first chunk arrives last; byte ranges identify the chunks.
      assert [{:ok, %ChunkResult{} = second}, {:ok, %ChunkResult{} = first}] = events
      assert [%{text: "Second"}] = second.spans
      assert [%{text: "First"}] = first.spans
      assert first.byte_start == 0
      assert second.byte_start > 0
    end

    test "run/4 output equals the collected-and-sorted stream (order restoration)" do
      counting_stub(self())
      opts = [max_chunk_chars: 25, max_concurrency: 2]

      assert {:ok, %Result{spans: run_spans, errors: []}} =
               LangExtract.run(claude_client(), @two_chunk_source, template(), opts)

      stream_spans =
        claude_client()
        |> LangExtract.stream(@two_chunk_source, template(), opts)
        |> Enum.map(fn {:ok, %ChunkResult{} = result} -> result end)
        |> Enum.sort_by(& &1.byte_start)
        |> Enum.flat_map(& &1.spans)

      assert stream_spans == run_spans
    end

    test "a timed-out chunk is a per-chunk error; survivors keep flowing" do
      # Margins matter under load: the fast chunk needs generous headroom
      # inside the timeout, and the slow chunk (150ms sleep) must sit well
      # past it — 100ms leaves ~2x on both sides.
      counting_stub(self())

      events =
        claude_client()
        |> LangExtract.stream(@two_chunk_source, template(),
          max_chunk_chars: 25,
          max_concurrency: 2,
          task_timeout: 100
        )
        |> Enum.to_list()

      assert [{:ok, %ChunkResult{spans: [%{text: "Second"}]}}, {:error, %ChunkError{} = error}] =
               events

      assert error.reason == {:task_exit, :timeout}
      assert error.byte_start == 0
    end

    test "emits document telemetry at consumption, including on early halt" do
      Telemetry.attach_own([
        [:lang_extract, :document, :start],
        [:lang_extract, :document, :stop]
      ])

      counting_stub(self())

      stream =
        LangExtract.stream(claude_client(), @two_chunk_source, template(),
          max_chunk_chars: 25,
          max_concurrency: 2
        )

      refute_receive {[:lang_extract, :document, :start], _, _}, 50

      assert [_one] = Enum.take(stream, 1)

      assert_receive {[:lang_extract, :document, :start], start_meas, _}
      assert is_integer(start_meas.system_time)

      assert_receive {[:lang_extract, :document, :stop], stop_meas, _}
      assert stop_meas.chunk_count == 2
      assert stop_meas.span_count == 1
      assert is_integer(stop_meas.duration)
    end
  end

  describe "LangExtract.new/2" do
    test "creates client with :claude provider" do
      client = LangExtract.new(:claude, api_key: "sk-test")
      assert %Client{provider: LangExtract.Provider.Claude, options: opts} = client
      assert opts[:api_key] == "sk-test"
    end

    test "creates client with :openai provider" do
      client = LangExtract.new(:openai, api_key: "sk-test")
      assert %Client{provider: LangExtract.Provider.OpenAI} = client
    end

    test "creates client with :gemini provider" do
      client = LangExtract.new(:gemini, api_key: "gm-test")
      assert %Client{provider: LangExtract.Provider.Gemini} = client
    end

    test "raises ArgumentError for unknown provider" do
      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        LangExtract.new(:unknown, api_key: "test")
      end
    end

    test "defaults options to empty list" do
      client = LangExtract.new(:claude, api_key: "test-key")
      assert client.options == [api_key: "test-key"]
    end
  end

  describe "LangExtract.run/3,4" do
    defp stub_claude(response_body, opts \\ []) do
      status = Keyword.get(opts, :status, 200)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(response_body))
      end)
    end

    defp claude_client do
      LangExtract.new(:claude, api_key: "sk-test", req_options: @req_options)
    end

    defp template(description \\ "Extract.") do
      %LangExtract.Template{description: description}
    end

    defp claude_extraction_response(extractions) do
      %{
        "content" => [
          %{"type" => "text", "text" => Jason.encode!(%{"extractions" => extractions})}
        ]
      }
    end

    test "full pipeline: prompt → LLM → parse → align → enriched spans" do
      stub_claude(
        claude_extraction_response([
          %{"word" => "fox", "word_attributes" => %{"type" => "noun"}}
        ])
      )

      assert {:ok, %Result{spans: [span], errors: []}} =
               LangExtract.run(claude_client(), "the quick brown fox", template("Extract words."))

      assert span.class == "word"
      assert span.text == "fox"
      assert span.status == :exact
      assert span.attributes == %{"type" => "noun"}
      assert span.byte_start == 16
      assert span.byte_end == 19
    end

    test "propagates provider error" do
      stub_claude(%{"error" => "unauthorized"}, status: 401)

      assert {:ok, %Result{spans: [], errors: [%ChunkError{reason: :unauthorized} = error]}} =
               LangExtract.run(claude_client(), "some text", template())

      assert error.byte_start == 0
      assert error.byte_end == byte_size("some text")
    end

    test "propagates error for LLM output missing extractions key" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"wrong_key" => []})}
          ]
        })
      end)

      assert {:ok,
              %Result{spans: [], errors: [%ChunkError{reason: :missing_extractions} = error]}} =
               LangExtract.run(claude_client(), "some text", template())

      assert error.byte_start == 0
      assert error.byte_end == byte_size("some text")
    end

    test "propagates format handler error for invalid LLM output" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "not valid json at all"}]
        })
      end)

      assert {:ok,
              %Result{spans: [], errors: [%ChunkError{reason: {:invalid_format, _raw}} = error]}} =
               LangExtract.run(claude_client(), "some text", template())

      assert error.byte_start == 0
      assert error.byte_end == byte_size("some text")
    end

    test "returns ok with empty list when LLM returns no extractions" do
      stub_claude(claude_extraction_response([]))

      assert {:ok, %Result{spans: [], errors: []}} =
               LangExtract.run(claude_client(), "some text", template())
    end

    test "extraction not found in source returns span with :not_found status" do
      stub_claude(
        claude_extraction_response([%{"thing" => "nonexistent", "thing_attributes" => %{}}])
      )

      assert {:ok, %Result{spans: [span], errors: []}} =
               LangExtract.run(claude_client(), "hello world", template())

      assert span.status == :not_found
      assert span.class == "thing"
    end

    test "fuzzy_threshold option is passed through to aligner" do
      stub_claude(
        claude_extraction_response([%{"phrase" => "quick brown dog", "phrase_attributes" => %{}}])
      )

      # High coverage bar with lesser disabled — not_found (2/3 = 0.67 < 0.75)
      assert {:ok, %Result{spans: [span], errors: []}} =
               LangExtract.run(claude_client(), "the quick brown fox jumps", template(),
                 accept_lesser: false
               )

      assert span.status == :not_found

      # Low threshold — fuzzy match
      assert {:ok, %Result{spans: [span], errors: []}} =
               LangExtract.run(claude_client(), "the quick brown fox jumps", template(),
                 fuzzy_threshold: 0.6,
                 accept_lesser: false
               )

      assert span.status == :fuzzy
    end

    test "max_chunk_chars triggers chunking with correct byte offsets" do
      source = "First sentence here. Second sentence there."

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        prompt = hd(decoded["messages"])["content"]

        extractions =
          if prompt =~ "First" do
            [%{"word" => "First", "word_attributes" => %{}}]
          else
            [%{"word" => "Second", "word_attributes" => %{}}]
          end

        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => extractions})}
          ]
        })
      end)

      assert {:ok, %Result{spans: spans, errors: []}} =
               LangExtract.run(claude_client(), source, template("Extract words."),
                 max_chunk_chars: 25
               )

      exact_spans = Enum.filter(spans, &(&1.status == :exact))

      for span <- exact_spans do
        length = span.byte_end - span.byte_start
        assert binary_part(source, span.byte_start, length) =~ span.text
      end
    end

    test "spans return in document order even when chunks complete out of order" do
      source = "First sentence here. Second sentence there."

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        prompt = hd(Jason.decode!(body)["messages"])["content"]

        # Delay the first chunk so the second one completes before it;
        # the unordered stream must still yield document order.
        extractions =
          if prompt =~ "First" do
            Process.sleep(150)
            [%{"word" => "First", "word_attributes" => %{}}]
          else
            [%{"word" => "Second", "word_attributes" => %{}}]
          end

        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => extractions})}
          ]
        })
      end)

      assert {:ok, %Result{spans: spans, errors: []}} =
               LangExtract.run(claude_client(), source, template("Extract words."),
                 max_chunk_chars: 25,
                 max_concurrency: 2
               )

      assert Enum.map(spans, & &1.text) == ["First", "Second"]

      assert spans |> Enum.map(& &1.byte_start) |> Enum.sort() ==
               Enum.map(spans, & &1.byte_start)
    end

    test "multi-byte extraction in a later chunk round-trips via byte offsets" do
      source = "Le café ouvrit à l'aube. Le señor Ahab vit la 🐳 baleine."

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        prompt = hd(Jason.decode!(body)["messages"])["content"]

        extractions =
          if prompt =~ "🐳" do
            [%{"sighting" => "🐳 baleine", "sighting_attributes" => %{}}]
          else
            []
          end

        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => extractions})}
          ]
        })
      end)

      assert {:ok, %Result{spans: [span], errors: []}} =
               LangExtract.run(claude_client(), source, template(), max_chunk_chars: 40)

      assert span.status == :exact
      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) == "🐳 baleine"
    end

    test "emits document and chunk telemetry spans" do
      Telemetry.attach([
        [:lang_extract, :document, :start],
        [:lang_extract, :document, :stop],
        [:lang_extract, :chunk, :stop]
      ])

      # Cross-suite discipline (see the census test below): a unique byte
      # size pins document events; chunk offsets past anything other
      # suites use pin chunk events. runner_test/chaos_test share the
      # short two-sentence fixture, so it can't be used under a global
      # telemetry handler.
      source = String.duplicate("Telemetry span sentence sits here. ", 30)
      source_bytes = byte_size(source)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => []})}
          ]
        })
      end)

      assert {:ok, %Result{spans: [], errors: []}} =
               LangExtract.run(claude_client(), source, template(), max_chunk_chars: 600)

      assert_receive {[:lang_extract, :document, :start], _, %{source_bytes: ^source_bytes}}

      assert_receive {[:lang_extract, :document, :stop], measurements,
                      %{source_bytes: ^source_bytes}}

      assert measurements.chunk_count == 2
      assert measurements.span_count == 0
      assert measurements.error_count == 0
      assert is_integer(measurements.duration)

      assert_receive {[:lang_extract, :chunk, :stop], chunk_meas,
                      %{byte_end: chunk_end} = chunk_meta}
                     when chunk_end > 500

      assert chunk_meas.span_count == 0
      assert chunk_meta.status == :ok
      assert is_integer(chunk_meta.byte_start) and is_integer(chunk_meta.byte_end)

      assert_receive {[:lang_extract, :chunk, :stop], _, %{byte_end: other_end}}
                     when other_end > 500
    end

    test "run/4 emits the full pre-streaming event census" do
      Telemetry.attach([
        [:lang_extract, :document, :start],
        [:lang_extract, :document, :stop],
        [:lang_extract, :chunk, :start],
        [:lang_extract, :chunk, :stop],
        [:lang_extract, :request, :start],
        [:lang_extract, :request, :stop]
      ])

      stub_claude(claude_extraction_response([]))

      # Concurrent async suites emit these events too, so every assertion
      # filters to this run: a source with a unique byte size (documents),
      # chunk offsets past anything other suites use (chunks), and a
      # dedicated model name (requests).
      census_source = String.duplicate("A census sentence stands right about here. ", 25)
      source_bytes = byte_size(census_source)

      census_client =
        LangExtract.new(:claude,
          api_key: "sk-test",
          model: "census-model",
          req_options: @req_options
        )

      assert {:ok, %Result{spans: _spans, errors: []}} =
               LangExtract.run(census_client, census_source, template(),
                 max_chunk_chars: 600,
                 max_concurrency: 2
               )

      # One document span with the span-shaped + domain measurement keys.
      assert_receive {[:lang_extract, :document, :start], %{system_time: _},
                      %{source_bytes: ^source_bytes}}

      assert_receive {[:lang_extract, :document, :stop], doc_stop, %{source_bytes: ^source_bytes}}

      assert doc_stop |> Map.keys() |> Enum.sort() ==
               [:chunk_count, :duration, :error_count, :monotonic_time, :span_count]

      chunk_count = doc_stop.chunk_count
      assert chunk_count >= 2

      # Every chunk: a start and a stop span, plus a request span.
      for _ <- 1..chunk_count do
        assert_receive {[:lang_extract, :chunk, :start], _, %{byte_end: chunk_end}}
                       when chunk_end > 500

        assert_receive {[:lang_extract, :chunk, :stop], %{duration: _, span_count: _},
                        %{byte_end: stop_end}}
                       when stop_end > 500

        assert_receive {[:lang_extract, :request, :start], _, %{model: "census-model"}}

        assert_receive {[:lang_extract, :request, :stop], %{duration: _},
                        %{model: "census-model"}}
      end

      refute_receive {[:lang_extract, :document, _], _, %{source_bytes: ^source_bytes}}
    end

    test "failed chunk emits :error status and counts into document error_count" do
      Telemetry.attach([[:lang_extract, :document, :stop], [:lang_extract, :chunk, :stop]])

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "not parseable at all"}]
        })
      end)

      # Unique byte size: chaos_test emits errored documents concurrently,
      # so error_count alone can't identify this run's events.
      source = "Unparseable census payload."
      source_bytes = byte_size(source)

      assert {:ok, %Result{spans: [], errors: [%ChunkError{}]}} =
               LangExtract.run(claude_client(), source, template())

      assert_receive {[:lang_extract, :chunk, :stop], %{span_count: 0},
                      %{status: :error, byte_end: ^source_bytes}}

      assert_receive {[:lang_extract, :document, :stop], %{error_count: 1},
                      %{source_bytes: ^source_bytes}}
    end

    test "chunk task timeout returns {:error, {:task_exit, :timeout}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        Process.sleep(200)
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "{}"}]})
      end)

      assert {:error, {:task_exit, :timeout}} =
               LangExtract.run(claude_client(), "some text", template(), task_timeout: 50)
    end

    test "auto-chunks by default (short text fits in one chunk)" do
      stub_claude(claude_extraction_response([%{"word" => "fox", "word_attributes" => %{}}]))

      assert {:ok, %Result{spans: [span], errors: []}} =
               LangExtract.run(claude_client(), "the quick brown fox", template())

      assert span.status == :exact
    end

    test "not_found span byte offsets are not adjusted in chunked mode" do
      stub_claude(claude_extraction_response([%{"thing" => "absent", "thing_attributes" => %{}}]))

      assert {:ok, %Result{spans: spans, errors: []}} =
               LangExtract.run(claude_client(), "Hello world. Goodbye world.", template(),
                 max_chunk_chars: 15
               )

      not_found = Enum.find(spans, &(&1.status == :not_found))
      assert not_found != nil
      assert not_found.byte_start == nil
      assert not_found.byte_end == nil
    end

    test "mixed success and failure returns partial spans with chunk errors" do
      counter = :counters.new(1, [])

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          Req.Test.json(conn, %{
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  Jason.encode!(%{
                    "extractions" => [%{"word" => "First", "word_attributes" => %{}}]
                  })
              }
            ]
          })
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "unauthorized"}))
        end
      end)

      assert {:ok, %Result{spans: spans, errors: errors}} =
               LangExtract.run(claude_client(), "First sentence. Second sentence.", template(),
                 max_chunk_chars: 20,
                 max_concurrency: 1
               )

      assert [%Span{text: "First", class: "word", status: :exact}] = spans
      assert [%ChunkError{reason: :unauthorized} = error] = errors
      assert error.byte_start > 0
    end

    test "provider error in chunked mode fails entire run" do
      stub_claude(%{"error" => "unauthorized"}, status: 401)

      assert {:ok,
              %Result{
                spans: [],
                errors: [
                  %ChunkError{reason: :unauthorized},
                  %ChunkError{reason: :unauthorized}
                ]
              }} =
               LangExtract.run(claude_client(), "First sentence. Second sentence.", template(),
                 max_chunk_chars: 20
               )
    end

    test "multiple extractions aligned independently" do
      stub_claude(
        claude_extraction_response([
          %{"animal" => "fox", "animal_attributes" => %{}},
          %{"animal" => "dog", "animal_attributes" => %{}}
        ])
      )

      assert {:ok, %Result{spans: [fox, dog], errors: []}} =
               LangExtract.run(
                 claude_client(),
                 "the quick brown fox jumps over the lazy dog",
                 template()
               )

      assert fox.text == "fox"
      assert fox.status == :exact
      assert dog.text == "dog"
      assert dog.status == :exact
    end
  end
end
