defmodule LangExtract.OrchestratorTest do
  use ExUnit.Case, async: true

  alias LangExtract.Client

  @req_options [plug: {Req.Test, __MODULE__}]

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
      client = LangExtract.new(:claude)
      assert client.options == []
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
      %LangExtract.Prompt.Template{description: description}
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

      assert {:ok, [span]} =
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

      assert {:error, :unauthorized} = LangExtract.run(claude_client(), "some text", template())
    end

    test "propagates error for LLM output missing extractions key" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"wrong_key" => []})}
          ]
        })
      end)

      assert {:error, :invalid_format} = LangExtract.run(claude_client(), "some text", template())
    end

    test "propagates format handler error for invalid LLM output" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "not valid json at all"}]
        })
      end)

      assert {:error, :invalid_format} = LangExtract.run(claude_client(), "some text", template())
    end

    test "returns ok with empty list when LLM returns no extractions" do
      stub_claude(claude_extraction_response([]))

      assert {:ok, []} = LangExtract.run(claude_client(), "some text", template())
    end

    test "extraction not found in source returns span with :not_found status" do
      stub_claude(
        claude_extraction_response([%{"thing" => "nonexistent", "thing_attributes" => %{}}])
      )

      assert {:ok, [span]} = LangExtract.run(claude_client(), "hello world", template())
      assert span.status == :not_found
      assert span.class == "thing"
    end

    test "fuzzy_threshold option is passed through to aligner" do
      stub_claude(
        claude_extraction_response([%{"phrase" => "quick brown dog", "phrase_attributes" => %{}}])
      )

      # Default threshold (0.75) — not_found (2/3 = 0.67 < 0.75)
      assert {:ok, [span]} =
               LangExtract.run(claude_client(), "the quick brown fox jumps", template())

      assert span.status == :not_found

      # Low threshold — fuzzy match
      assert {:ok, [span]} =
               LangExtract.run(claude_client(), "the quick brown fox jumps", template(),
                 fuzzy_threshold: 0.6
               )

      assert span.status == :fuzzy
    end

    test "max_chunk_size triggers chunking with correct byte offsets" do
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

      assert {:ok, spans} =
               LangExtract.run(claude_client(), source, template("Extract words."),
                 max_chunk_size: 25
               )

      exact_spans = Enum.filter(spans, &(&1.status == :exact))

      for span <- exact_spans do
        length = span.byte_end - span.byte_start
        assert binary_part(source, span.byte_start, length) =~ span.text
      end
    end

    test "no max_chunk_size behaves as before (regression)" do
      stub_claude(claude_extraction_response([%{"word" => "fox", "word_attributes" => %{}}]))

      assert {:ok, [span]} =
               LangExtract.run(claude_client(), "the quick brown fox", template())

      assert span.status == :exact
    end

    test "not_found span byte offsets are not adjusted in chunked mode" do
      stub_claude(claude_extraction_response([%{"thing" => "absent", "thing_attributes" => %{}}]))

      assert {:ok, spans} =
               LangExtract.run(claude_client(), "Hello world. Goodbye world.", template(),
                 max_chunk_size: 15
               )

      not_found = Enum.find(spans, &(&1.status == :not_found))
      assert not_found != nil
      assert not_found.byte_start == nil
      assert not_found.byte_end == nil
    end

    test "provider error in chunked mode fails entire run" do
      stub_claude(%{"error" => "unauthorized"}, status: 401)

      assert {:error, :unauthorized} =
               LangExtract.run(claude_client(), "First sentence. Second sentence.", template(),
                 max_chunk_size: 20
               )
    end

    test "multiple extractions aligned independently" do
      stub_claude(
        claude_extraction_response([
          %{"animal" => "fox", "animal_attributes" => %{}},
          %{"animal" => "dog", "animal_attributes" => %{}}
        ])
      )

      assert {:ok, [fox, dog]} =
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
