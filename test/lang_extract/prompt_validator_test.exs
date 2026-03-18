defmodule LangExtract.PromptValidatorTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Extraction, ExampleData, PromptTemplate, PromptValidator}

  describe "validate/1" do
    test "returns :ok when all examples align exactly" do
      template = %PromptTemplate{
        description: "Extract conditions.",
        examples: [
          %ExampleData{
            text: "Patient has hypertension and diabetes.",
            extractions: [
              %Extraction{class: "condition", text: "hypertension", attributes: %{}},
              %Extraction{class: "condition", text: "diabetes", attributes: %{}}
            ]
          }
        ]
      }

      assert :ok = PromptValidator.validate(template)
    end
  end
end
