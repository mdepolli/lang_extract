defmodule LangExtract.WireFormatTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.WireFormat

  describe "format_extractions/1" do
    test "serializes a single extraction to dynamic-key JSON with fences" do
      extraction = %Extraction{
        class: "medical_condition",
        text: "hypertension",
        attributes: %{"chronicity" => "chronic"}
      }

      result = WireFormat.format_extractions([extraction])

      assert String.starts_with?(result, "```json\n")
      assert String.ends_with?(result, "\n```")

      decoded = decode_fenced(result)
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

      result = WireFormat.format_extractions(extractions)
      decoded = decode_fenced(result)

      assert length(decoded["extractions"]) == 2

      [first, second] = decoded["extractions"]
      assert first["drug"] == "aspirin"
      assert second["dosage"] == "100mg"
      assert second["dosage_attributes"] == %{"unit" => "mg"}
    end

    test "serializes extraction with empty attributes" do
      extraction = %Extraction{class: "symptom", text: "headache", attributes: %{}}

      result = WireFormat.format_extractions([extraction])
      decoded = decode_fenced(result)

      [item] = decoded["extractions"]
      assert item["symptom"] == "headache"
      assert item["symptom_attributes"] == %{}
    end

    test "serializes empty extraction list" do
      result = WireFormat.format_extractions([])
      decoded = decode_fenced(result)

      assert decoded == %{"extractions" => []}
    end

    test "handles nil attributes without error" do
      extraction = %Extraction{class: "thing", text: "stuff", attributes: nil}

      result = WireFormat.format_extractions([extraction])
      decoded = decode_fenced(result)

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

      result = WireFormat.format_extractions([extraction])
      decoded = decode_fenced(result)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "aspirin", "attributes" => %{}}
               ]
             }
    end

    test "strips unclosed <think> tag to end of string" do
      input = "<think>This is an unclosed think block that eats everything"

      assert {:error, {:invalid_format, ^input}} = WireFormat.normalize(input)
    end

    test "strips multiple <think> blocks" do
      input = """
      <think>first reasoning</think>
      extractions:
      - symptom: fever
        symptom_attributes: {}
      <think>second thought</think>
      """

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "ibuprofen", "attributes" => %{}}
               ]
             }
    end

    test "returns error for non-YAML content" do
      assert {:error, {:invalid_format, "just plain text"}} =
               WireFormat.normalize("just plain text")
    end

    test "passes through valid YAML without extractions key" do
      assert {:ok, %{"wrong_key" => []}} =
               WireFormat.normalize("wrong_key: []")
    end

    test "quotes unquoted YAML values containing colons" do
      yaml = """
      extractions:
        - dialogue: work and service: and these
          dialogue_attributes:
            speaker: Someone
      """

      assert {:ok, %{"extractions" => [entry]}} = WireFormat.normalize(yaml)
      assert entry["text"] == "work and service: and these"
    end

    test "preserves already-quoted YAML values" do
      yaml = """
      extractions:
        - dialogue: "already quoted: value"
          dialogue_attributes:
            speaker: Someone
      """

      assert {:ok, %{"extractions" => [entry]}} = WireFormat.normalize(yaml)
      assert entry["text"] == "already quoted: value"
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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

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

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{"extractions" => [%{}]}
    end
  end

  describe "round-trip" do
    test "format_extractions |> normalize |> Parser.parse returns same extractions" do
      alias LangExtract.Pipeline.Parser

      extractions = [
        %Extraction{
          class: "medical_condition",
          text: "hypertension",
          attributes: %{"chronicity" => "chronic"}
        },
        %Extraction{class: "drug", text: "lisinopril", attributes: %{}}
      ]

      formatted = WireFormat.format_extractions(extractions)
      assert {:ok, normalized} = WireFormat.normalize(formatted)
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

  describe "normalize/1 with block scalars" do
    test "preserves literal block scalar values" do
      input = """
      extractions:
        - dialogue: |-
            Two households, both alike in dignity,
            In fair Verona, where we lay our scene.
          dialogue_attributes:
            speaker: Chorus
      """

      assert {:ok, decoded} = WireFormat.normalize(input)
      assert [entry] = decoded["extractions"]
      assert entry["class"] == "dialogue"

      assert entry["text"] ==
               "Two households, both alike in dignity,\nIn fair Verona, where we lay our scene."

      assert entry["attributes"] == %{"speaker" => "Chorus"}
    end

    test "preserves folded block scalars" do
      input = """
      extractions:
        - dialogue: >-
            Sweet is the scent of the hawthorn,
            and sweet are the bluebells.
          dialogue_attributes:
            speaker: Nightingale
      """

      assert {:ok, decoded} = WireFormat.normalize(input)
      assert [entry] = decoded["extractions"]
      assert entry["text"] == "Sweet is the scent of the hawthorn, and sweet are the bluebells."
    end

    test "repairs an unterminated leading quote" do
      # Real Sonnet 5 defect: the model opens a quoted scalar on the last
      # entry and never closes it, swallowing the rest of the document.
      input = """
      extractions:
        - dialogue: "Death is a great price to pay for a red rose,"
          dialogue_attributes:
            speaker: the Nightingale
        - dialogue: "and Life is very dear to all.
          dialogue_attributes:
            speaker: the Nightingale
      """

      assert {:ok, decoded} = WireFormat.normalize(input)
      assert [first, second] = decoded["extractions"]
      assert first["text"] == "Death is a great price to pay for a red rose,"
      assert second["text"] == "and Life is very dear to all."
    end

    test "repairs unescaped quotes inside a quoted value" do
      input = """
      extractions:
        - dialogue: "Well," said he, "I believe you."
          dialogue_attributes:
            speaker: he
      """

      assert {:ok, decoded} = WireFormat.normalize(input)
      assert [entry] = decoded["extractions"]
      assert entry["text"] == ~s(Well," said he, "I believe you.)
    end

    test "repairs multi-line plain scalars containing colons" do
      input = """
      extractions:
        - dialogue: What, drawn, and talk of peace? I hate the word
            As I hate hell, all Montagues, and thee:
            Have at thee, coward.
          dialogue_attributes:
            speaker: TYBALT
      """

      assert {:ok, decoded} = WireFormat.normalize(input)
      assert [entry] = decoded["extractions"]
      assert entry["text"] =~ "I hate the word As I hate hell, all Montagues, and thee:"
    end

    test "still quotes plain values containing colon-space" do
      input = """
      extractions:
        - dialogue: Friar Lawrence said: be patient
          dialogue_attributes: {}
      """

      assert {:ok, decoded} = WireFormat.normalize(input)
      assert [entry] = decoded["extractions"]
      assert entry["text"] == "Friar Lawrence said: be patient"
    end
  end

  # Strips the ```json ... ``` fences and decodes the JSON body.
  defp decode_fenced(fenced) do
    fenced
    |> String.replace_prefix("```json\n", "")
    |> String.replace_suffix("\n```", "")
    |> Jason.decode!()
  end
end
