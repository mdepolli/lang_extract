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
  end
end
