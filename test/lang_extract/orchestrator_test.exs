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
  end
end
