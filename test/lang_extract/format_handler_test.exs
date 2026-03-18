defmodule LangExtract.FormatHandlerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.FormatHandler

  describe "format_extractions/1" do
    test "serializes a single extraction to dynamic-key JSON with fences" do
      extraction = %Extraction{
        class: "medical_condition",
        text: "hypertension",
        attributes: %{"chronicity" => "chronic"}
      }

      result = FormatHandler.format_extractions([extraction])

      assert String.starts_with?(result, "```json\n")
      assert String.ends_with?(result, "\n```")

      decoded = decode_fenced_json(result)
      [item] = decoded["extractions"]

      assert item["medical_condition"] == "hypertension"
      assert item["medical_condition_attributes"] == %{"chronicity" => "chronic"}

      refute Map.has_key?(item, "class")
      refute Map.has_key?(item, "text")
    end

    test "serializes multiple extractions in order" do
      extractions = [
        %Extraction{class: "drug", text: "aspirin", attributes: %{}},
        %Extraction{class: "dosage", text: "100mg", attributes: %{"unit" => "mg"}}
      ]

      result = FormatHandler.format_extractions(extractions)
      decoded = decode_fenced_json(result)

      assert length(decoded["extractions"]) == 2

      [first, second] = decoded["extractions"]
      assert first["drug"] == "aspirin"
      assert second["dosage"] == "100mg"
      assert second["dosage_attributes"] == %{"unit" => "mg"}
    end

    test "serializes extraction with empty attributes" do
      extraction = %Extraction{class: "symptom", text: "headache", attributes: %{}}

      result = FormatHandler.format_extractions([extraction])
      decoded = decode_fenced_json(result)

      [item] = decoded["extractions"]
      assert item["symptom"] == "headache"
      assert item["symptom_attributes"] == %{}
    end

    test "serializes empty extraction list" do
      result = FormatHandler.format_extractions([])
      decoded = decode_fenced_json(result)

      assert decoded == %{"extractions" => []}
    end

    test "preserves nested attributes" do
      extraction = %Extraction{
        class: "finding",
        text: "mass",
        attributes: %{
          "location" => %{
            "organ" => "lung",
            "side" => "left",
            "lobe" => %{"upper" => true}
          }
        }
      }

      result = FormatHandler.format_extractions([extraction])
      decoded = decode_fenced_json(result)

      [item] = decoded["extractions"]
      location = item["finding_attributes"]["location"]

      assert location["organ"] == "lung"
      assert location["side"] == "left"
      assert location["lobe"] == %{"upper" => true}
    end
  end

  # Strips the ```json ... ``` fences and decodes the JSON body.
  defp decode_fenced_json(fenced) do
    fenced
    |> String.replace_prefix("```json\n", "")
    |> String.replace_suffix("\n```", "")
    |> Jason.decode!()
  end
end
