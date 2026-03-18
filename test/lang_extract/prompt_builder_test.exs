defmodule LangExtract.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias LangExtract.{ExampleData, Extraction, PromptBuilder, PromptTemplate}

  describe "build/3" do
    test "renders description and chunk text with no examples" do
      template = %PromptTemplate{
        description: "Extract entities from the text."
      }

      result = PromptBuilder.build(template, "The quick brown fox.")

      assert result =~ "Extract entities from the text."
      assert result =~ "The quick brown fox."
      refute result =~ "```json"
    end
  end
end
