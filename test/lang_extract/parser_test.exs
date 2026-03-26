defmodule LangExtract.ParserTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Extraction, Parser}

  describe "parse/1" do
    test "parses valid JSON with all fields" do
      json =
        Jason.encode!(%{
          "extractions" => [
            %{
              "class" => "character",
              "text" => "ROMEO",
              "attributes" => %{"emotion" => "wonder"}
            },
            %{"class" => "location", "text" => "Verona", "attributes" => %{}}
          ]
        })

      assert {:ok, extractions} = Parser.parse(json)
      assert length(extractions) == 2

      assert %Extraction{class: "character", text: "ROMEO", attributes: %{"emotion" => "wonder"}} =
               hd(extractions)

      assert %Extraction{class: "location", text: "Verona", attributes: %{}} =
               List.last(extractions)
    end

    test "returns empty list for empty extractions" do
      json = Jason.encode!(%{"extractions" => []})
      assert {:ok, []} = Parser.parse(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_json} = Parser.parse("not json at all")
    end

    test "returns error when extractions key is missing" do
      json = Jason.encode!(%{"data" => []})
      assert {:error, :missing_extractions} = Parser.parse(json)
    end

    test "returns error when extractions is not a list" do
      json = Jason.encode!(%{"extractions" => "oops"})
      assert {:error, :missing_extractions} = Parser.parse(json)

      json_null = Jason.encode!(%{"extractions" => nil})
      assert {:error, :missing_extractions} = Parser.parse(json_null)
    end

    test "skips entries with missing class or text" do
      json =
        Jason.encode!(%{
          "extractions" => [
            %{"class" => "valid", "text" => "kept"},
            %{"text" => "no class"},
            %{"class" => "no text"}
          ]
        })

      assert {:ok, [%Extraction{class: "valid", text: "kept"}]} = Parser.parse(json)
    end

    test "skips entries with non-string class or text" do
      json =
        Jason.encode!(%{
          "extractions" => [
            %{"class" => 42, "text" => "bad class"},
            %{"class" => "good", "text" => nil},
            %{"class" => "valid", "text" => "kept"}
          ]
        })

      assert {:ok, [%Extraction{class: "valid", text: "kept"}]} = Parser.parse(json)
    end

    test "skips entries with empty string class or text" do
      json =
        Jason.encode!(%{
          "extractions" => [
            %{"class" => "", "text" => "empty class"},
            %{"class" => "valid", "text" => ""},
            %{"class" => "good", "text" => "kept"}
          ]
        })

      assert {:ok, [%Extraction{class: "good", text: "kept"}]} = Parser.parse(json)
    end

    test "defaults missing attributes to empty map" do
      json =
        Jason.encode!(%{
          "extractions" => [%{"class" => "x", "text" => "y"}]
        })

      assert {:ok, [%Extraction{attributes: %{}}]} = Parser.parse(json)
    end

    test "defaults non-map attributes to empty map" do
      json =
        Jason.encode!(%{
          "extractions" => [%{"class" => "x", "text" => "y", "attributes" => "bad"}]
        })

      assert {:ok, [%Extraction{attributes: %{}}]} = Parser.parse(json)
    end

    test "preserves nested attributes" do
      json =
        Jason.encode!(%{
          "extractions" => [
            %{"class" => "x", "text" => "y", "attributes" => %{"nested" => %{"deep" => true}}}
          ]
        })

      assert {:ok, [%Extraction{attributes: %{"nested" => %{"deep" => true}}}]} =
               Parser.parse(json)
    end
  end

  describe "LangExtract.extract/3" do
    test "parses, aligns, and merges class/attributes onto spans" do
      source = "But soft! What light through yonder window breaks?"

      json =
        Jason.encode!(%{
          "extractions" => [
            %{"class" => "quote", "text" => "soft", "attributes" => %{"tone" => "gentle"}},
            %{"class" => "object", "text" => "window"}
          ]
        })

      assert {:ok, spans} = LangExtract.extract(source, json)
      assert length(spans) == 2

      [soft, window] = spans

      assert %LangExtract.Alignment.Span{
               text: "soft",
               status: :exact,
               class: "quote",
               attributes: %{"tone" => "gentle"}
             } = soft

      assert soft.byte_start != nil

      assert %LangExtract.Alignment.Span{
               text: "window",
               status: :exact,
               class: "object",
               attributes: %{}
             } = window

      assert window.byte_start != nil
    end

    test "merges class/attributes onto not_found spans" do
      json =
        Jason.encode!(%{
          "extractions" => [
            %{"class" => "thing", "text" => "nonexistent phrase", "attributes" => %{"a" => 1}}
          ]
        })

      assert {:ok, [span]} = LangExtract.extract("hello world", json)
      assert span.status == :not_found
      assert span.class == "thing"
      assert span.attributes == %{"a" => 1}
    end

    test "propagates parser errors" do
      assert {:error, {:invalid_format, "bad json"}} = LangExtract.extract("source", "bad json")

      raw = Jason.encode!(%{"wrong" => []})
      assert {:error, {:invalid_format, ^raw}} = LangExtract.extract("source", raw)
    end

    test "handles dynamic-key format from LLM output" do
      source = "The patient was diagnosed with hypertension."

      json =
        Jason.encode!(%{
          "extractions" => [
            %{
              "medical_condition" => "hypertension",
              "medical_condition_attributes" => %{"chronicity" => "chronic"}
            }
          ]
        })

      assert {:ok, [span]} = LangExtract.extract(source, json)
      assert span.class == "medical_condition"
      assert span.text == "hypertension"
      assert span.attributes == %{"chronicity" => "chronic"}
      assert span.status == :exact
    end
  end
end
