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

    test "strips markdown fences with json language tag" do
      json = ~s(```json\n{"extractions": [{"class": "x", "text": "y"}]}\n```)
      assert {:ok, [%Extraction{class: "x", text: "y"}]} = Parser.parse(json)
    end

    test "strips markdown fences without language tag" do
      json = ~s(```\n{"extractions": [{"class": "x", "text": "y"}]}\n```)
      assert {:ok, [%Extraction{class: "x", text: "y"}]} = Parser.parse(json)
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
end
