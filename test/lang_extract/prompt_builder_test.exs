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
              %Extraction{
                class: "condition",
                text: "diabetes",
                attributes: %{"type" => "chronic"}
              }
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

    test "includes previous chunk context" do
      template = %PromptTemplate{description: "Extract."}

      result =
        PromptBuilder.build(template, "Current chunk.", previous_chunk: "Previous text here.")

      assert result =~ "[Previous text]: ...Previous text here."
      assert result =~ "Current chunk."
    end

    test "truncates previous chunk to context_window_chars" do
      template = %PromptTemplate{description: "Extract."}

      result =
        PromptBuilder.build(template, "Current.",
          previous_chunk: "This is a long previous chunk of text.",
          context_window_chars: 10
        )

      assert result =~ "[Previous text]: ...k of text."
      refute result =~ "This is a long"
    end

    test "omits context section when no previous chunk" do
      template = %PromptTemplate{description: "Extract."}

      result = PromptBuilder.build(template, "Current chunk.")

      refute result =~ "[Previous text]"
    end

    test "empty description is valid" do
      template = %PromptTemplate{
        description: "",
        examples: [
          %ExampleData{
            text: "Example text.",
            extractions: [%Extraction{class: "thing", text: "text", attributes: %{}}]
          }
        ]
      }

      result = PromptBuilder.build(template, "Target text.")

      assert result =~ "Example text."
      assert result =~ "Target text."
      refute String.starts_with?(result, "\n")
    end
  end
end
