defmodule LangExtract.OrchestratorTest do
  use ExUnit.Case, async: true

  alias LangExtract.Client

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
    setup do
      HTTPower.Test.setup()
    end

    test "full pipeline: prompt → LLM → parse → align → enriched spans" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [
                    %{"word" => "fox", "word_attributes" => %{"type" => "noun"}}
                  ]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")

      template = %LangExtract.Prompt.Template{
        description: "Extract words from the text."
      }

      assert {:ok, [span]} = LangExtract.run(client, "the quick brown fox", template)
      assert span.class == "word"
      assert span.text == "fox"
      assert span.status == :exact
      assert span.attributes == %{"type" => "noun"}
      assert span.byte_start == 16
      assert span.byte_end == 19
    end

    test "propagates provider error" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{"error" => "unauthorized"}, status: 401)
      end)

      client = LangExtract.new(:claude, api_key: "bad-key")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:error, :unauthorized} = LangExtract.run(client, "some text", template)
    end

    test "propagates error for LLM output missing extractions key" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"wrong_key" => []})}
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      # FormatHandler.normalize/1 catches missing "extractions" key before the parser
      assert {:error, :invalid_format} = LangExtract.run(client, "some text", template)
    end

    test "propagates format handler error for invalid LLM output" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "not valid json at all"}]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:error, :invalid_format} = LangExtract.run(client, "some text", template)
    end

    test "returns ok with empty list when LLM returns no extractions" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => []})}
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, []} = LangExtract.run(client, "some text", template)
    end

    test "extraction not found in source returns span with :not_found status" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [%{"thing" => "nonexistent", "thing_attributes" => %{}}]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, [span]} = LangExtract.run(client, "hello world", template)
      assert span.status == :not_found
      assert span.class == "thing"
    end

    test "fuzzy_threshold option is passed through to aligner" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [
                    %{"phrase" => "quick brown dog", "phrase_attributes" => %{}}
                  ]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      # Default threshold (0.75) — not_found (2/3 = 0.67 < 0.75)
      assert {:ok, [span]} =
               LangExtract.run(client, "the quick brown fox jumps", template)

      assert span.status == :not_found

      # Low threshold — fuzzy match
      assert {:ok, [span]} =
               LangExtract.run(client, "the quick brown fox jumps", template,
                 fuzzy_threshold: 0.6
               )

      assert span.status == :fuzzy
    end

    test "max_chunk_size triggers chunking with correct byte offsets" do
      source = "First sentence here. Second sentence there."

      HTTPower.Test.stub(fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        prompt = hd(decoded["messages"])["content"]

        extractions =
          if prompt =~ "First" do
            [%{"word" => "First", "word_attributes" => %{}}]
          else
            [%{"word" => "Second", "word_attributes" => %{}}]
          end

        HTTPower.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => extractions})}
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract words."}

      assert {:ok, spans} =
               LangExtract.run(client, source, template, max_chunk_size: 25)

      exact_spans = Enum.filter(spans, &(&1.status == :exact))

      for span <- exact_spans do
        length = span.byte_end - span.byte_start
        assert binary_part(source, span.byte_start, length) =~ span.text
      end
    end

    test "no max_chunk_size behaves as before (regression)" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" => Jason.encode!(%{"extractions" => [%{"word" => "fox", "word_attributes" => %{}}]})
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, [span]} = LangExtract.run(client, "the quick brown fox", template)
      assert span.status == :exact
    end

    test "not_found span byte offsets are not adjusted in chunked mode" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" => Jason.encode!(%{"extractions" => [%{"thing" => "absent", "thing_attributes" => %{}}]})
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, spans} =
               LangExtract.run(client, "Hello world. Goodbye world.", template,
                 max_chunk_size: 15
               )

      not_found = Enum.find(spans, &(&1.status == :not_found))
      assert not_found != nil
      assert not_found.byte_start == nil
      assert not_found.byte_end == nil
    end

    test "provider error in chunked mode fails entire run" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{"error" => "unauthorized"}, status: 401)
      end)

      client = LangExtract.new(:claude, api_key: "bad")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:error, :unauthorized} =
               LangExtract.run(client, "First sentence. Second sentence.", template,
                 max_chunk_size: 20
               )
    end

    test "multiple extractions aligned independently" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [
                    %{"animal" => "fox", "animal_attributes" => %{}},
                    %{"animal" => "dog", "animal_attributes" => %{}}
                  ]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, [fox, dog]} =
               LangExtract.run(
                 client,
                 "the quick brown fox jumps over the lazy dog",
                 template
               )

      assert fox.text == "fox"
      assert fox.status == :exact
      assert dog.text == "dog"
      assert dog.status == :exact
    end
  end
end
