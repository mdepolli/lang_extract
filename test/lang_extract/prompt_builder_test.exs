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

    test "renders few-shot examples in dynamic-key format" do
      template = %PromptTemplate{
        description: "Extract conditions.",
        examples: [
          %ExampleData{
            text: "Patient has diabetes.",
            extractions: [
              %Extraction{class: "condition", text: "diabetes", attributes: %{"type" => "chronic"}}
            ]
          }
        ]
      }

      result = PromptBuilder.build(template, "Patient has asthma.")

      assert result =~ "Extract conditions."
      assert result =~ "Patient has diabetes."
      assert result =~ "\"condition\""
      assert result =~ "\"diabetes\""
      assert result =~ "condition_attributes"
      assert String.ends_with?(String.trim(result), "Patient has asthma.")
    end
  end
end
