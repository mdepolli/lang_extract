defmodule LangExtract.WireFormatTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.Pipeline.Parser
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
    test "converts dynamic-key entries to canonical format" do
      input =
        Jason.encode!(%{
          "extractions" => [
            %{
              "medical_condition" => "hypertension",
              "medical_condition_attributes" => %{"chronicity" => "chronic"}
            }
          ]
        })

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

    test "passes through already-canonical entries unchanged" do
      input =
        Jason.encode!(%{
          "extractions" => [%{"class" => "drug", "text" => "aspirin", "attributes" => %{}}]
        })

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "aspirin", "attributes" => %{}}
               ]
             }
    end

    test "passes through canonical entry with extra keys untouched" do
      input =
        Jason.encode!(%{
          "extractions" => [
            %{
              "class" => "drug",
              "text" => "aspirin",
              "attributes" => %{},
              "html_attributes" => "data-id='5'"
            }
          ]
        })

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

    # A canonical marker key without its partner is a malformed echo of the
    # canonical schema, not a dynamic-key group. Rewriting it would
    # fabricate an extraction out of the schema's own key names
    # (class: "class", text: "drug"); passthrough lets Parser skip and log.
    test "canonical entry missing one field passes through for Parser to skip" do
      input = Jason.encode!(%{"extractions" => [%{"class" => "drug"}, %{"text" => "orphan"}]})

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{"extractions" => [%{"class" => "drug"}, %{"text" => "orphan"}]}
    end

    # The verbatim-span instruction makes the model echo source content —
    # including code fences and literal think tags — inside extraction
    # strings. Sanitizer regexes have no JSON-string awareness, so they
    # must never run on a payload that already parses (or whose fence
    # extraction parses) without them.
    test "fence characters inside an extraction string survive" do
      payload =
        Jason.encode!(%{
          "extractions" => [
            %{"code" => "```elixir\ndef f, do: :ok\n```", "code_attributes" => %{}}
          ]
        })

      assert {:ok, %{"extractions" => [entry]}} =
               WireFormat.normalize("```json\n#{payload}\n```")

      assert entry["text"] == "```elixir\ndef f, do: :ok\n```"
    end

    test "a literal think tag inside an extraction string survives" do
      payload = Jason.encode!(%{"extractions" => [%{"quote" => "he said <think> aloud"}]})

      for raw <- [payload, "```json\n#{payload}\n```"] do
        assert {:ok, %{"extractions" => [entry]}} = WireFormat.normalize(raw)
        assert entry["text"] == "he said <think> aloud"
      end
    end

    test "strips <think> tags before parsing" do
      payload =
        Jason.encode!(%{"extractions" => [%{"drug" => "aspirin", "drug_attributes" => %{}}]})

      input = "<think>Let me reason about this carefully.</think>\n" <> payload

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
      payload =
        Jason.encode!(%{"extractions" => [%{"symptom" => "fever", "symptom_attributes" => %{}}]})

      input = "<think>first reasoning</think>\n" <> payload <> "\n<think>second thought</think>"

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "symptom", "text" => "fever", "attributes" => %{}}
               ]
             }
    end

    test "strips fences regardless of language tag" do
      inner =
        Jason.encode!(%{"extractions" => [%{"drug" => "ibuprofen", "drug_attributes" => %{}}]})

      input = "```yaml\n#{inner}\n```"

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
      inner2 =
        Jason.encode!(%{"extractions" => [%{"drug" => "ibuprofen", "drug_attributes" => %{}}]})

      input = "```\n#{inner2}\n```"

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "drug", "text" => "ibuprofen", "attributes" => %{}}
               ]
             }
    end

    test "returns error for unparseable content" do
      assert {:error, {:invalid_format, "just plain text"}} =
               WireFormat.normalize("just plain text")
    end

    test "handles combined think tags, fences, and dynamic keys" do
      inner =
        Jason.encode!(%{
          "extractions" => [%{"finding" => "mass", "finding_attributes" => %{"size" => "2cm"}}]
        })

      input = "<think>Thinking...</think>\n```json\n#{inner}\n```"

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "finding", "text" => "mass", "attributes" => %{"size" => "2cm"}}
               ]
             }
    end

    test "_attributes key without matching prefix is treated as a class key" do
      input = Jason.encode!(%{"extractions" => [%{"html_attributes" => "<b>bold</b>"}]})

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "html_attributes", "text" => "<b>bold</b>", "attributes" => %{}}
               ]
             }
    end

    # Upstream coerces int/float extraction values via str(); other
    # non-string values raise there, but skip-and-log here (Parser's
    # per-entry guard), keeping the chunk alive.
    test "numeric extraction values coerce to strings" do
      input = Jason.encode!(%{"extractions" => [%{"dosage" => 100}, %{"ratio" => 2.5}]})

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{
               "extractions" => [
                 %{"class" => "dosage", "text" => "100", "attributes" => %{}},
                 %{"class" => "ratio", "text" => "2.5", "attributes" => %{}}
               ]
             }
    end

    test "entry with no keys is passed through" do
      input = Jason.encode!(%{"extractions" => [%{}]})

      assert {:ok, decoded} = WireFormat.normalize(input)

      assert decoded == %{"extractions" => [%{}]}
    end

    test "parses a fenced JSON response in dynamic-key format" do
      raw = ~s(```json\n{"extractions": [{"person": "Ahab", "person_attributes": {}}]}\n```)

      assert {:ok, %{"extractions" => [entry]}} = WireFormat.normalize(raw)
      assert entry["class"] == "person"
      assert entry["text"] == "Ahab"
    end

    test "parses strings containing control characters" do
      raw = ~s({"extractions": [{"note": "a\\tb", "note_attributes": {}}]})

      assert {:ok, %{"extractions" => [entry]}} = WireFormat.normalize(raw)
      assert entry["class"] == "note"
      assert entry["text"] == "a\tb"
    end

    test "JSON without extractions key passes through for Parser to reject" do
      assert {:ok, %{"other" => 1}} = WireFormat.normalize(~s({"other": 1}))
    end

    # {} is the same semantic condition as any other extractions-less
    # object; splitting the taxonomy ({} as :invalid_format, {"other":1}
    # as :missing_extractions) made consumers branching on reason shape
    # treat one model behavior two ways.
    test "empty object routes to :missing_extractions like any extractions-less object" do
      assert WireFormat.normalize("{}") == {:ok, %{}}
      assert LangExtract.extract("source", "{}") == {:error, :missing_extractions}
    end

    # Encode/decode agreement: what format_extractions emits, decoding
    # recovers intact — Parser.parse states the result as structs.
    test "format_extractions |> normalize |> Parser.parse returns same extractions" do
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

    # Regression pin for the composed drop: before the multi-key expansion,
    # normalize passed a merged entry through whole and Parser's class/text
    # guard skipped it — both halves individually tested, the seam between
    # them not, and every extraction in the entry vanished with only a log
    # line. Expansion, sorted key order (a decoded map cannot keep JSON
    # insertion order), and per-key _attributes pairing are all pinned
    # here through the structs.
    test "a merged multi-class entry yields all its extractions through Parser" do
      input =
        Jason.encode!(%{
          "extractions" => [
            %{
              "drug" => "aspirin",
              "dosage" => "100mg",
              "drug_attributes" => %{"route" => "oral"}
            }
          ]
        })

      assert {:ok, normalized} = WireFormat.normalize(input)
      assert {:ok, parsed} = Parser.parse(normalized)

      assert [
               %Extraction{class: "dosage", text: "100mg", attributes: %{}},
               %Extraction{class: "drug", text: "aspirin", attributes: %{"route" => "oral"}}
             ] = parsed
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
