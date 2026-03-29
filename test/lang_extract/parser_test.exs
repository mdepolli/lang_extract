defmodule LangExtract.ParserTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Extraction, Parser}

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

      yaml = """
      extractions:
      - quote: soft
        quote_attributes:
          tone: gentle
      - object: window
      """

      assert {:ok, spans} = LangExtract.extract(source, yaml)
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
      yaml = """
      extractions:
      - thing: nonexistent phrase
        thing_attributes:
          a: 1
      """

      assert {:ok, [span]} = LangExtract.extract("hello world", yaml)
      assert span.status == :not_found
      assert span.class == "thing"
      assert span.attributes == %{"a" => 1}
    end

    test "propagates format errors" do
      assert {:error, {:invalid_format, "bad input"}} =
               LangExtract.extract("source", "bad input")

      raw = "wrong_key:\n- a: 1"
      assert {:error, {:invalid_format, ^raw}} = LangExtract.extract("source", raw)
    end

    test "handles dynamic-key format from LLM output" do
      source = "The patient was diagnosed with hypertension."

      yaml = """
      extractions:
      - medical_condition: hypertension
        medical_condition_attributes:
          chronicity: chronic
      """

      assert {:ok, [span]} = LangExtract.extract(source, yaml)
      assert span.class == "medical_condition"
      assert span.text == "hypertension"
      assert span.attributes == %{"chronicity" => "chronic"}
      assert span.status == :exact
    end
  end
end
