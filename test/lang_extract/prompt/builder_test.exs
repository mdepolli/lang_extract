defmodule LangExtract.Prompt.BuilderTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.Prompt.Builder
  alias LangExtract.Template
  alias LangExtract.Template.Example

  describe "build/2" do
    test "renders description and chunk text with no examples" do
      template = %Template{
        description: "Extract entities from the text."
      }

      result = Builder.build(template, "The quick brown fox.")

      assert result =~ "Extract entities from the text."
      assert result =~ "The quick brown fox."
      refute result =~ "```yaml"
    end

    test "renders few-shot examples in dynamic-key format" do
      template = %Template{
        description: "Extract conditions.",
        examples: [
          %Example{
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

      result = Builder.build(template, "Patient has asthma.")

      assert result =~ "Extract conditions."
      assert result =~ "Examples"
      assert result =~ "Q: Patient has diabetes."
      assert result =~ ~s("condition": "diabetes")
      assert result =~ "condition_attributes"
      # Upstream QAPromptGenerator framing: final question, bare answer primer.
      assert result =~ "Q: Patient has asthma."
      assert String.ends_with?(String.trim(result), "A:")
      # The answer fence comes from WireFormat — exactly one per example.
      assert length(String.split(result, "```json")) == 2
    end

    test "includes verbatim extraction instructions before the passage" do
      template = %Template{description: "Extract things."}

      result = Builder.build(template, "The passage.")

      assert result =~ "verbatim"
      assert result =~ ~s(output {"extractions": []})

      [_pre, post] = String.split(result, "verbatim", parts: 2)
      assert post =~ "The passage."
    end

    test "empty description is valid" do
      template = %Template{
        description: "",
        examples: [
          %Example{
            text: "Example text.",
            extractions: [%Extraction{class: "thing", text: "text", attributes: %{}}]
          }
        ]
      }

      result = Builder.build(template, "Target text.")

      assert result =~ "Example text."
      assert result =~ "Target text."
      refute String.starts_with?(result, "\n")
    end
  end
end
