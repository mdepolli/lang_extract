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
      error =
        assert_raise ValidationError, fn ->
          LangExtract.template("Extract.",
            examples: [
              %{
                text: "the quick brown fox",
                extractions: [%{class: "x", text: "purple elephant"}]
              }
            ]
          )
        end

      assert length(error.issues) == 1
      assert Exception.message(error) =~ "1 alignment issue(s) found"
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

    # The classic examples/extractions mix-up: :extractions defaults to
    # [], so an extraction passed as an example would otherwise build a
    # validated template whose few-shot example teaches the model to
    # extract nothing — with no error at construction or run time.
    test "extraction-shaped maps as examples raise ArgumentError" do
      for example <- [
            %{class: "condition", text: "diabetes"},
            %{"class" => "condition", "text" => "diabetes"},
            %Extraction{class: "condition", text: "diabetes"}
          ] do
        assert_raise ArgumentError, ~r/extraction-shaped/, fn ->
          LangExtract.template("Extract.", examples: [example])
        end
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

    # WireFormat reserves "class" and "text" as canonical marker keys — a
    # dynamic-key encode of class "text" echoes as {"text": "..."} and the
    # decoder treats it as a marker, so every conforming reply is skipped.
    test "reserved extraction class names class and text raise ArgumentError" do
      for class <- ["class", "text"] do
        assert_raise ArgumentError, ~r/reserved class name/, fn ->
          LangExtract.template("Extract.",
            examples: [%{text: "hello", extractions: [%{class: class, text: "hello"}]}]
          )
        end
      end

      assert_raise ArgumentError, ~r/reserved class name/, fn ->
        LangExtract.template("Extract.",
          examples: [
            %{
              text: "hello",
              extractions: [%Extraction{class: "text", text: "hello"}]
            }
          ]
        )
      end
    end

    # Any dynamic key ending in "_attributes" is an attributes carrier on
    # the wire: class "note_attributes" would decode as attributes for
    # class "note", silently mangling every conforming reply.
    test "extraction classes ending in _attributes raise ArgumentError" do
      assert_raise ArgumentError, ~r/reserved suffix "_attributes"/, fn ->
        LangExtract.template("Extract.",
          examples: [
            %{text: "hello", extractions: [%{class: "note_attributes", text: "hello"}]}
          ]
        )
      end
    end

    # Explicit null/false must not collapse to the field default via || —
    # that is the silent teach-nothing path the extractions: null top-level
    # case already rejects.
    test "explicit null extractions raises rather than becoming an empty list" do
      assert_raise ArgumentError, ~r/example key :extractions must be a list, got: nil/, fn ->
        LangExtract.template("Extract.",
          examples: [%{"text" => "hello", "extractions" => nil}]
        )
      end
    end

    test "explicit false attributes raises rather than becoming an empty map" do
      assert_raise ArgumentError, ~r/extraction key :attributes must be a map, got: false/, fn ->
        LangExtract.template("Extract.",
          examples: [
            %{text: "hello world", extractions: [%{class: "w", text: "hello", attributes: false}]}
          ]
        )
      end
    end

    test "explicit null extraction text raises a type error not a missing-key error" do
      assert_raise ArgumentError, ~r/extraction key :text must be a string, got: nil/, fn ->
        LangExtract.template("Extract.",
          examples: [%{text: "hello", extractions: [%{"class" => "w", "text" => nil}]}]
        )
      end
    end

    # Validation runs the production aligner, so aligner behavior changes
    # are silently template/2 API changes. Nested mentions are the most
    # common few-shot shape; upstream grounds them (dp_nested_* fixtures),
    # and examples using them must keep building.
    test "examples with nested extractions build" do
      example = %{
        text: "Patient has type 2 diabetes.",
        extractions: [
          %{class: "condition", text: "type 2 diabetes"},
          %{class: "entity", text: "diabetes"}
        ]
      }

      assert %Template{examples: [%Example{extractions: [container, nested]}]} =
               LangExtract.template("Extract conditions.", examples: [example])

      assert container.text == "type 2 diabetes"
      assert nested.text == "diabetes"
    end
  end
end
