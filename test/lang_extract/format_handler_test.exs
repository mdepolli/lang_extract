defmodule LangExtract.FormatHandlerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.FormatHandler

  describe "format_extractions/1" do
    test "serializes a single extraction to dynamic-key YAML with fences" do
      extraction = %Extraction{
        class: "medical_condition",
        text: "hypertension",
        attributes: %{"chronicity" => "chronic"}
      }

      result = FormatHandler.format_extractions([extraction])

      assert String.starts_with?(result, "```yaml\n")
      assert String.ends_with?(result, "\n```")

      decoded = decode_fenced_yaml(result)
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
      decoded = decode_fenced_yaml(result)

      assert length(decoded["extractions"]) == 2

      [first, second] = decoded["extractions"]
      assert first["drug"] == "aspirin"
      assert second["dosage"] == "100mg"
      assert second["dosage_attributes"] == %{"unit" => "mg"}
    end

    test "serializes extraction with empty attributes" do
      extraction = %Extraction{class: "symptom", text: "headache", attributes: %{}}

      result = FormatHandler.format_extractions([extraction])
      decoded = decode_fenced_yaml(result)

      [item] = decoded["extractions"]
      assert item["symptom"] == "headache"
      assert item["symptom_attributes"] == %{}
    end

    test "serializes empty extraction list" do
      result = FormatHandler.format_extractions([])
      decoded = decode_fenced_yaml(result)

      assert decoded == %{"extractions" => []}
    end

    test "handles nil attributes without error" do
      extraction = %Extraction{class: "thing", text: "stuff", attributes: nil}

      result = FormatHandler.format_extractions([extraction])
      decoded = decode_fenced_yaml(result)

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
      decoded = decode_fenced_yaml(result)

      [item] = decoded["extractions"]
      location = item["finding_attributes"]["location"]

      assert location["organ"] == "lung"
      assert location["side"] == "left"
      assert location["lobe"] == %{"upper" => true}
    end
  end

  describe "normalize/1" do
    test "converts dynamic-key YAML to canonical format" do
      input = """
      extractions:
      - medical_condition: hypertension
        medical_condition_attributes:
          chronicity: chronic
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

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

    test "passes through already-canonical YAML unchanged" do
      input = """
      extractions:
      - class: drug
        text: aspirin
        attributes: {}
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "aspirin", "attributes" => %{}}
               ]
             }
    end

    test "passes through canonical entry with extra keys untouched" do
      input = """
      extractions:
      - class: drug
        text: aspirin
        attributes: {}
        html_attributes: "data-id='5'"
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{
                   "class" => "drug",
                   "text" => "aspirin",
                   "attributes" => %{},
                   "html_attributes" => "data-id='5'"
                 }
               ]
             }
    end

    test "strips <think> tags before parsing" do
      input = """
      <think>Let me reason about this carefully.</think>
      extractions:
      - drug: aspirin
        drug_attributes: {}
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "aspirin", "attributes" => %{}}
               ]
             }
    end

    test "strips unclosed <think> tag to end of string" do
      input = "<think>This is an unclosed think block that eats everything"

      assert {:error, {:invalid_format, ^input}} = FormatHandler.normalize(input)
    end

    test "strips multiple <think> blocks" do
      input = """
      <think>first reasoning</think>
      extractions:
      - symptom: fever
        symptom_attributes: {}
      <think>second thought</think>
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "symptom", "text" => "fever", "attributes" => %{}}
               ]
             }
    end

    test "strips markdown fences with yaml language tag" do
      input = """
      ```yaml
      extractions:
      - drug: ibuprofen
        drug_attributes: {}
      ```
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "ibuprofen", "attributes" => %{}}
               ]
             }
    end

    test "strips markdown fences with json language tag" do
      inner =
        Jason.encode!(%{"extractions" => [%{"drug" => "ibuprofen", "drug_attributes" => %{}}]})

      input = "```json\n#{inner}\n```"

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "ibuprofen", "attributes" => %{}}
               ]
             }
    end

    test "strips markdown fences without language tag" do
      input = """
      ```
      extractions:
      - drug: ibuprofen
        drug_attributes: {}
      ```
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "ibuprofen", "attributes" => %{}}
               ]
             }
    end

    test "returns error for content without extractions key" do
      assert {:error, {:invalid_format, "just plain text"}} =
               FormatHandler.normalize("just plain text")
    end

    test "handles combined think tags, fences, and dynamic keys" do
      input = """
      <think>Thinking...</think>
      ```yaml
      extractions:
      - finding: mass
        finding_attributes:
          size: 2cm
      ```
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "finding", "text" => "mass", "attributes" => %{"size" => "2cm"}}
               ]
             }
    end

    test "_attributes key without matching prefix is treated as a class key" do
      input = """
      extractions:
      - html_attributes: "<b>bold</b>"
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "html_attributes", "text" => "<b>bold</b>", "attributes" => %{}}
               ]
             }
    end

    test "entry with multiple non-attribute keys is passed through" do
      input = """
      extractions:
      - drug: aspirin
        dosage: 100mg
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"drug" => "aspirin", "dosage" => "100mg"}
               ]
             }
    end

    test "entry with no keys is passed through" do
      input = """
      extractions:
      - {}
      """

      assert {:ok, decoded} = FormatHandler.normalize(input)

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

  # Strips the ```yaml ... ``` fences and decodes the YAML body.
  defp decode_fenced_yaml(fenced) do
    fenced
    |> String.replace_prefix("```yaml\n", "")
    |> String.replace_suffix("\n```", "")
    |> YamlElixir.read_from_string!()
  end
end
