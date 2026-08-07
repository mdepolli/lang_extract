defmodule LangExtractTest do
  use ExUnit.Case, async: true

  alias LangExtract.Extraction
  alias LangExtract.Prompt.Validator.ValidationError
  alias LangExtract.Template
  alias LangExtract.Template.Example

  doctest LangExtract

  describe "template/2" do
    test "accepts string-keyed maps (JSON-loaded task definitions)" do
      template =
        LangExtract.template("Extract entities.",
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
        LangExtract.template("Extract entities.",
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
               LangExtract.template("Extract.", examples: [example])
    end

    test "misaligned examples raise ValidationError at construction" do
      assert_raise ValidationError, fn ->
        LangExtract.template("Extract.",
          examples: [
            %{text: "the quick brown fox", extractions: [%{class: "x", text: "purple elephant"}]}
          ]
        )
      end
    end

    test "missing required keys raise ArgumentError naming the owner" do
      assert_raise ArgumentError, ~r/example is missing required key :text/, fn ->
        LangExtract.template("Extract.", examples: [%{extractions: []}])
      end

      assert_raise ArgumentError, ~r/extraction is missing required key :class/, fn ->
        LangExtract.template("Extract.",
          examples: [%{text: "hello", extractions: [%{text: "hello"}]}]
        )
      end
    end

    test "a description-only template needs no examples" do
      assert %Template{description: "Extract.", examples: []} = LangExtract.template("Extract.")
    end

    # A JSON task definition's "examples": null must fail as a named
    # argument error at the call site, not as Protocol.UndefinedError
    # from inside Enum.
    test "non-list :examples raises ArgumentError naming the field" do
      for bad <- [nil, "not a list", %{}] do
        assert_raise ArgumentError, ~r/must be a list/, fn ->
          LangExtract.template("Extract.", examples: bad)
        end
      end
    end

    test "wrong-typed fields raise ArgumentError naming the field" do
      assert_raise ArgumentError, ~r/example key :text must be a string, got: 42/, fn ->
        LangExtract.template("Extract.", examples: [%{text: 42}])
      end

      assert_raise ArgumentError, ~r/example key :extractions must be a list/, fn ->
        LangExtract.template("Extract.", examples: [%{text: "hello", extractions: "nope"}])
      end

      assert_raise ArgumentError, ~r/extraction key :attributes must be a map/, fn ->
        LangExtract.template("Extract.",
          examples: [
            %{
              text: "hello world",
              extractions: [%{class: "w", text: "hello", attributes: "bogus"}]
            }
          ]
        )
      end

      assert_raise ArgumentError, ~r/extraction key :class must be a string, got: 42/, fn ->
        LangExtract.template("Extract.",
          examples: [%{text: "hello", extractions: [%{class: 42, text: "hello"}]}]
        )
      end
    end

    test "non-map examples and extractions raise ArgumentError" do
      assert_raise ArgumentError, ~r/example must be a map/, fn ->
        LangExtract.template("Extract.", examples: ["nope"])
      end

      assert_raise ArgumentError, ~r/extraction must be a map, got: 42/, fn ->
        LangExtract.template("Extract.", examples: [%{text: "hello", extractions: [42]}])
      end
    end
  end
end
