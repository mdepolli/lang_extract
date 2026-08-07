defmodule LangExtract.Pipeline.ParserTest do
  use ExUnit.Case, async: true

  # Invalid-entry tests deliberately trigger Parser's skip warnings.
  @moduletag capture_log: true

  alias LangExtract.Extraction
  alias LangExtract.Pipeline.Parser

  describe "parse/1" do
    test "parses valid map with all fields" do
      input = %{
        "extractions" => [
          %{
            "class" => "character",
            "text" => "ROMEO",
            "attributes" => %{"emotion" => "wonder"}
          },
          %{"class" => "location", "text" => "Verona", "attributes" => %{}}
        ]
      }

      assert {:ok, extractions} = Parser.parse(input)
      assert length(extractions) == 2

      assert %Extraction{class: "character", text: "ROMEO", attributes: %{"emotion" => "wonder"}} =
               hd(extractions)

      assert %Extraction{class: "location", text: "Verona", attributes: %{}} =
               List.last(extractions)
    end

    test "returns empty list for empty extractions" do
      assert {:ok, []} = Parser.parse(%{"extractions" => []})
    end

    test "returns error when extractions key is missing" do
      assert {:error, :missing_extractions} = Parser.parse(%{"data" => []})
    end

    test "returns error when extractions is not a list" do
      assert {:error, :missing_extractions} = Parser.parse(%{"extractions" => "oops"})
      assert {:error, :missing_extractions} = Parser.parse(%{"extractions" => nil})
    end

    test "skips entries with missing class or text" do
      input = %{
        "extractions" => [
          %{"class" => "valid", "text" => "kept"},
          %{"text" => "no class"},
          %{"class" => "no text"}
        ]
      }

      assert {:ok, [%Extraction{class: "valid", text: "kept"}]} = Parser.parse(input)
    end

    test "skips entries with non-string class or text" do
      input = %{
        "extractions" => [
          %{"class" => 42, "text" => "bad class"},
          %{"class" => "good", "text" => nil},
          %{"class" => "valid", "text" => "kept"}
        ]
      }

      assert {:ok, [%Extraction{class: "valid", text: "kept"}]} = Parser.parse(input)
    end

    # Skipped entries carry model-echoed source text (clinical corpora:
    # PHI). The no-payloads rule the telemetry events follow extends to
    # the app log: shape only, never values.
    test "skip warnings log entry shape, never payload values" do
      import ExUnit.CaptureLog

      input = %{"extractions" => [%{"class" => "condition", "text" => 42}, "PATIENT-DATA"]}

      log =
        capture_log(fn ->
          assert {:ok, []} = Parser.parse(input)
        end)

      assert log =~ "Skipping invalid extraction entry"
      assert log =~ ~s(keys: ["class", "text"])
      refute log =~ "PATIENT-DATA"
      refute log =~ "condition"
    end

    test "skips entries with empty string class or text" do
      input = %{
        "extractions" => [
          %{"class" => "", "text" => "empty class"},
          %{"class" => "valid", "text" => ""},
          %{"class" => "good", "text" => "kept"}
        ]
      }

      assert {:ok, [%Extraction{class: "good", text: "kept"}]} = Parser.parse(input)
    end

    test "defaults missing attributes to empty map" do
      input = %{"extractions" => [%{"class" => "x", "text" => "y"}]}

      assert {:ok, [%Extraction{attributes: %{}}]} = Parser.parse(input)
    end

    test "defaults non-map attributes to empty map" do
      input = %{"extractions" => [%{"class" => "x", "text" => "y", "attributes" => "bad"}]}

      assert {:ok, [%Extraction{attributes: %{}}]} = Parser.parse(input)
    end

    test "preserves nested attributes" do
      input = %{
        "extractions" => [
          %{"class" => "x", "text" => "y", "attributes" => %{"nested" => %{"deep" => true}}}
        ]
      }

      assert {:ok, [%Extraction{attributes: %{"nested" => %{"deep" => true}}}]} =
               Parser.parse(input)
    end
  end

  describe "LangExtract.extract/3" do
    test "parses, aligns, and merges class/attributes onto spans" do
      source = "But soft! What light through yonder window breaks?"

      raw =
        Jason.encode!(%{
          "extractions" => [
            %{"quote" => "soft", "quote_attributes" => %{"tone" => "gentle"}},
            %{"object" => "window"}
          ]
        })

      assert {:ok, spans} = LangExtract.extract(source, raw)
      assert length(spans) == 2

      [soft, window] = spans

      assert %LangExtract.Span{
               text: "soft",
               status: :exact,
               class: "quote",
               attributes: %{"tone" => "gentle"}
             } = soft

      assert soft.byte_start != nil

      assert %LangExtract.Span{
               text: "window",
               status: :exact,
               class: "object",
               attributes: %{}
             } = window

      assert window.byte_start != nil
    end

    test "merges class/attributes onto not_found spans" do
      raw =
        Jason.encode!(%{
          "extractions" => [
            %{"thing" => "nonexistent phrase", "thing_attributes" => %{"a" => 1}}
          ]
        })

      assert {:ok, [span]} = LangExtract.extract("hello world", raw)
      assert span.status == :not_found
      assert span.class == "thing"
      assert span.attributes == %{"a" => 1}
    end

    test "propagates format errors for unparseable input" do
      assert {:error, {:invalid_format, "bad input"}} =
               LangExtract.extract("source", "bad input")
    end

    test "propagates missing_extractions for valid JSON without extractions key" do
      assert {:error, :missing_extractions} =
               LangExtract.extract("source", ~s({"wrong_key": [{"a": 1}]}))
    end

    test "handles dynamic-key format from LLM output" do
      source = "The patient was diagnosed with hypertension."

      raw =
        Jason.encode!(%{
          "extractions" => [
            %{
              "medical_condition" => "hypertension",
              "medical_condition_attributes" => %{"chronicity" => "chronic"}
            }
          ]
        })

      assert {:ok, [span]} = LangExtract.extract(source, raw)
      assert span.class == "medical_condition"
      assert span.text == "hypertension"
      assert span.attributes == %{"chronicity" => "chronic"}
      assert span.status == :exact
    end
  end
end
