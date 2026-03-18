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

    test "handles nil attributes without error" do
      extraction = %Extraction{class: "thing", text: "stuff", attributes: nil}

      result = FormatHandler.format_extractions([extraction])
      decoded = decode_fenced_json(result)

      [item] = decoded["extractions"]
      assert item["thing"] == "stuff"
      assert item["thing_attributes"] == nil
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

  describe "normalize/1" do
    test "converts dynamic-key JSON to canonical format" do
      input =
        Jason.encode!(%{
          "extractions" => [
            %{
              "medical_condition" => "hypertension",
              "medical_condition_attributes" => %{"chronicity" => "chronic"}
            }
          ]
        })

      assert {:ok, json} = FormatHandler.normalize(input)
      decoded = Jason.decode!(json)

      assert decoded == %{
               "extractions" => [
                 %{
                   "class" => "medical_condition",
                   "text" => "hypertension",
                   "attributes" => %{"chronicity" => "chronic"}
                 }
               ]
             }
    end

    test "passes through already-canonical JSON unchanged" do
      entry = %{"class" => "drug", "text" => "aspirin", "attributes" => %{}}
      input = Jason.encode!(%{"extractions" => [entry]})

      assert {:ok, json} = FormatHandler.normalize(input)
      decoded = Jason.decode!(json)

      assert decoded == %{"extractions" => [entry]}
    end

    test "passes through canonical entry with extra keys untouched" do
      entry = %{
        "class" => "drug",
        "text" => "aspirin",
        "attributes" => %{},
        "html_attributes" => "data-id='5'"
      }

      input = Jason.encode!(%{"extractions" => [entry]})

      assert {:ok, json} = FormatHandler.normalize(input)
      decoded = Jason.decode!(json)

      assert decoded == %{"extractions" => [entry]}
    end

    test "strips <think> tags before parsing" do
      think_content = "<think>Let me reason about this carefully.</think>"
      json = Jason.encode!(%{"extractions" => [%{"drug" => "aspirin", "drug_attributes" => %{}}]})
      input = "#{think_content}\n#{json}"

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "aspirin", "attributes" => %{}}
               ]
             }
    end

    test "strips unclosed <think> tag to end of string" do
      input = "<think>This is an unclosed think block that eats the JSON"

      assert {:error, :invalid_format} = FormatHandler.normalize(input)
    end

    test "strips multiple <think> blocks" do
      json =
        Jason.encode!(%{"extractions" => [%{"symptom" => "fever", "symptom_attributes" => %{}}]})

      input = "<think>first reasoning</think>\n#{json}\n<think>second thought</think>"

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "symptom", "text" => "fever", "attributes" => %{}}
               ]
             }
    end

    test "strips markdown fences with json language tag" do
      inner =
        Jason.encode!(%{"extractions" => [%{"drug" => "ibuprofen", "drug_attributes" => %{}}]})

      input = "```json\n#{inner}\n```"

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "ibuprofen", "attributes" => %{}}
               ]
             }
    end

    test "strips markdown fences without language tag" do
      inner =
        Jason.encode!(%{"extractions" => [%{"drug" => "ibuprofen", "drug_attributes" => %{}}]})

      input = "```\n#{inner}\n```"

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "ibuprofen", "attributes" => %{}}
               ]
             }
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_format} = FormatHandler.normalize("not valid json at all")
    end

    test "handles combined think tags, fences, and dynamic keys" do
      inner =
        Jason.encode!(%{
          "extractions" => [%{"finding" => "mass", "finding_attributes" => %{"size" => "2cm"}}]
        })

      input = "<think>Thinking...</think>\n```json\n#{inner}\n```"

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "finding", "text" => "mass", "attributes" => %{"size" => "2cm"}}
               ]
             }
    end

    test "_attributes key without matching prefix is treated as a class key" do
      # "html_attributes" has no "html" key, so it's the effective class key itself
      input = Jason.encode!(%{"extractions" => [%{"html_attributes" => "<b>bold</b>"}]})

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "html_attributes", "text" => "<b>bold</b>", "attributes" => %{}}
               ]
             }
    end

    test "entry with multiple non-attribute keys is passed through" do
      entry = %{"drug" => "aspirin", "dosage" => "100mg"}
      input = Jason.encode!(%{"extractions" => [entry]})

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{"extractions" => [entry]}
    end

    test "entry with no keys is passed through" do
      input = Jason.encode!(%{"extractions" => [%{}]})

      assert {:ok, result} = FormatHandler.normalize(input)
      decoded = Jason.decode!(result)

      assert decoded == %{"extractions" => [%{}]}
    end
  end

  describe "round-trip" do
    test "format_extractions |> normalize |> Parser.parse returns same extractions" do
      alias LangExtract.Parser

      extractions = [
        %Extraction{
          class: "medical_condition",
          text: "hypertension",
          attributes: %{"chronicity" => "chronic"}
        },
        %Extraction{class: "drug", text: "lisinopril", attributes: %{}}
      ]

      formatted = FormatHandler.format_extractions(extractions)
      assert {:ok, normalized} = FormatHandler.normalize(formatted)
      assert {:ok, parsed} = Parser.parse(normalized)

      assert length(parsed) == 2

      assert Enum.at(parsed, 0) == %Extraction{
               class: "medical_condition",
               text: "hypertension",
               attributes: %{"chronicity" => "chronic"}
             }

      assert Enum.at(parsed, 1) == %Extraction{class: "drug", text: "lisinopril", attributes: %{}}
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
