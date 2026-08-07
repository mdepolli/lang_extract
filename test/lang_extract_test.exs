defmodule LangExtractTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.Prompt.Validator.ValidationError
  alias LangExtract.Template
  alias LangExtract.Template.Example

  doctest LangExtract

  describe "template!/2" do
    test "accepts string-keyed maps (JSON-loaded task definitions)" do
      template =
        LangExtract.template!("Extract entities.",
          examples: [
            %{
              "text" => "Ahab sailed from Nantucket.",
              "extractions" => [
                %{"class" => "person", "text" => "Ahab"},
                %{"class" => "place", "text" => "Nantucket", "attributes" => %{"kind" => "port"}}
              ]
            }
          ]
        )

      assert %Template{examples: [%Example{extractions: [ahab, nantucket]}]} = template
      assert %Extraction{class: "person", text: "Ahab", attributes: %{}} = ahab
      assert nantucket.attributes == %{"kind" => "port"}
    end

    test "normalizes atom attribute keys to strings, matching the wire format" do
      template =
        LangExtract.template!("Extract entities.",
          examples: [
            %{
              text: "Ahab sailed from Nantucket.",
              extractions: [
                %{class: "place", text: "Nantucket", attributes: %{"sea" => true, kind: "port"}}
              ]
            }
          ]
        )

      assert %Template{examples: [%Example{extractions: [nantucket]}]} = template
      assert nantucket.attributes == %{"kind" => "port", "sea" => true}
    end

    test "accepts ready-made structs unchanged" do
      example = %Example{
        text: "hello world",
        extractions: [%Extraction{class: "w", text: "hello"}]
      }

      assert %Template{examples: [^example]} =
               LangExtract.template!("Extract.", examples: [example])
    end

    test "misaligned examples raise ValidationError at construction" do
      assert_raise ValidationError, fn ->
        LangExtract.template!("Extract.",
          examples: [
            %{text: "the quick brown fox", extractions: [%{class: "x", text: "purple elephant"}]}
          ]
        )
      end
    end

    test "missing required keys raise ArgumentError naming the owner" do
      assert_raise ArgumentError, ~r/example is missing required key :text/, fn ->
        LangExtract.template!("Extract.", examples: [%{extractions: []}])
      end

      assert_raise ArgumentError, ~r/extraction is missing required key :class/, fn ->
        LangExtract.template!("Extract.",
          examples: [%{text: "hello", extractions: [%{text: "hello"}]}]
        )
      end
    end

    test "a description-only template needs no examples" do
      assert %Template{description: "Extract.", examples: []} = LangExtract.template!("Extract.")
    end
  end

  describe "template/2" do
    test "returns {:ok, template} on valid input" do
      assert {:ok, %Template{description: "Extract.", examples: [%Example{}]}} =
               LangExtract.template("Extract.",
                 examples: [%{text: "hello world", extractions: [%{class: "w", text: "hello"}]}]
               )
    end

    test "returns the ValidationError misaligned examples would raise" do
      assert {:error, %ValidationError{issues: [_ | _]}} =
               LangExtract.template("Extract.",
                 examples: [
                   %{text: "the quick brown fox", extractions: [%{class: "x", text: "zebra"}]}
                 ]
               )
    end

    test "returns the ArgumentError malformed maps would raise" do
      assert {:error, %ArgumentError{message: message}} =
               LangExtract.template("Extract.", examples: [%{extractions: []}])

      assert message =~ "example is missing required key :text"
    end

    # The whole point of the tuple variant is runtime task definitions —
    # where a JSON file's "examples": null is routine. It must come back
    # as data, not blow up as Protocol.UndefinedError mid-Enum.
    test "non-list :examples returns ArgumentError instead of raising" do
      for bad <- [nil, "not a list", %{}] do
        assert {:error, %ArgumentError{message: message}} =
                 LangExtract.template("Extract.", examples: bad)

        assert message =~ "must be a list"
      end
    end

    test "wrong-typed fields return ArgumentError naming the field" do
      assert {:error, %ArgumentError{message: message}} =
               LangExtract.template("Extract.", examples: [%{text: 42}])

      assert message =~ "example key :text must be a string, got: 42"

      assert {:error, %ArgumentError{message: message}} =
               LangExtract.template("Extract.", examples: [%{text: "hello", extractions: "nope"}])

      assert message =~ ~s(example key :extractions must be a list, got: "nope")

      assert {:error, %ArgumentError{message: message}} =
               LangExtract.template("Extract.",
                 examples: [
                   %{
                     text: "hello world",
                     extractions: [%{class: "w", text: "hello", attributes: "bogus"}]
                   }
                 ]
               )

      assert message =~ ~s(extraction key :attributes must be a map, got: "bogus")

      assert {:error, %ArgumentError{message: message}} =
               LangExtract.template("Extract.",
                 examples: [%{text: "hello", extractions: [%{class: 42, text: "hello"}]}]
               )

      assert message =~ "extraction key :class must be a string, got: 42"
    end

    test "non-map examples and extractions return ArgumentError instead of raising" do
      assert {:error, %ArgumentError{message: message}} =
               LangExtract.template("Extract.", examples: ["nope"])

      assert message =~ ~s(example must be a map, got: "nope")

      assert {:error, %ArgumentError{message: message}} =
               LangExtract.template("Extract.", examples: [%{text: "hello", extractions: [42]}])

      assert message =~ "extraction must be a map, got: 42"
    end
  end
end
