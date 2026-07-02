defmodule LangExtract.Prompt.ValidatorTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.Prompt.{ExampleData, Template, Validator}

  describe "validate/1" do
    test "returns :ok when all examples align exactly" do
      template = %Template{
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

      assert :ok = Validator.validate(template)
    end

    test "returns error with :not_found when extraction text is not in source" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has hypertension.",
            extractions: [
              %Extraction{class: "drug", text: "tylenol", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = Validator.validate(template)
      assert issue.example_index == 0
      assert issue.extraction_index == 0
      assert issue.extraction_text == "tylenol"
      assert issue.extraction_class == "drug"
      assert issue.status == :not_found
      assert issue.example_text == "Patient has hypertension."
    end

    test "respects fuzzy_threshold — same extraction is :not_found at high threshold" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "the quick brown fox jumps",
            extractions: [
              %Extraction{class: "phrase", text: "quick brown dog", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = Validator.validate(template, fuzzy_threshold: 0.99)
      assert issue.status == :not_found
    end

    test "returns error with :fuzzy when extraction partially matches" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "the quick brown fox jumps",
            extractions: [
              # 2 of 3 tokens match — fuzzy at low threshold
              %Extraction{class: "phrase", text: "quick brown dog", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = Validator.validate(template, fuzzy_threshold: 0.6)
      assert issue.status == :fuzzy
    end

    test "collects multiple issues across multiple examples" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has hypertension.",
            extractions: [
              %Extraction{class: "condition", text: "hypertension", attributes: %{}},
              %Extraction{class: "drug", text: "aspirin", attributes: %{}}
            ]
          },
          %ExampleData{
            text: "Prescribed lisinopril.",
            extractions: [
              %Extraction{class: "drug", text: "metformin", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, issues} = Validator.validate(template)
      assert length(issues) == 2

      [first, second] = issues
      assert first.example_index == 0
      assert first.extraction_index == 1
      assert first.extraction_text == "aspirin"
      assert second.example_index == 1
      assert second.extraction_index == 0
      assert second.extraction_text == "metformin"
    end

    test "returns :ok for template with no examples" do
      template = %Template{description: "Extract."}
      assert :ok = Validator.validate(template)
    end

    test "returns :ok for example with no extractions" do
      template = %Template{
        description: "Extract.",
        examples: [%ExampleData{text: "Some text."}]
      }

      assert :ok = Validator.validate(template)
    end

    test "extraction with empty text produces :not_found issue" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Some text here.",
            extractions: [
              %Extraction{class: "thing", text: "", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = Validator.validate(template)
      assert issue.status == :not_found
      assert issue.extraction_text == ""
    end

    test "duplicate extraction texts within one example both align" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Take aspirin daily with aspirin.",
            extractions: [
              %Extraction{class: "drug", text: "aspirin", attributes: %{}},
              %Extraction{class: "drug", text: "aspirin", attributes: %{}}
            ]
          }
        ]
      }

      assert :ok = Validator.validate(template)
    end
  end

  describe "validate!/1" do
    test "returns :ok when all examples align" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has diabetes.",
            extractions: [
              %Extraction{class: "condition", text: "diabetes", attributes: %{}}
            ]
          }
        ]
      }

      assert :ok = Validator.validate!(template)
    end

    test "raises ValidationError with issues when alignment fails" do
      template = %Template{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has diabetes.",
            extractions: [
              %Extraction{class: "drug", text: "tylenol", attributes: %{}}
            ]
          }
        ]
      }

      error =
        assert_raise Validator.ValidationError, fn ->
          Validator.validate!(template)
        end

      assert length(error.issues) == 1
      assert Exception.message(error) =~ "1 alignment issue(s) found"
    end
  end
end
