defmodule LangExtract.Alignment.AlignerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.{Aligner, Span}

  describe "exact matching" do
    test "aligns a single word" do
      assert [%Span{text: "fox", byte_start: 16, byte_end: 19, status: :exact}] =
               Aligner.align("the quick brown fox", ["fox"])
    end

    test "aligns a multi-word phrase" do
      assert [%Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact}] =
               Aligner.align("the quick brown fox", ["quick brown"])
    end

    test "matches case-insensitively" do
      assert [%Span{text: "hello", byte_start: 0, byte_end: 5, status: :exact}] =
               Aligner.align("Hello world", ["hello"])
    end

    test "aligns multiple extractions independently" do
      source = "the quick brown fox jumps over the lazy dog"

      assert [
               %Span{text: "quick brown", status: :exact},
               %Span{text: "lazy dog", status: :exact}
             ] = Aligner.align(source, ["quick brown", "lazy dog"])
    end

    test "first occurrence wins for duplicates" do
      source = "hello world hello"

      assert [%Span{text: "hello", byte_start: 0, byte_end: 5, status: :exact}] =
               Aligner.align(source, ["hello"])
    end

    test "matches across punctuation boundaries" do
      source = "Hello, world!"

      assert [%Span{text: "Hello", byte_start: 0, byte_end: 5, status: :exact}] =
               Aligner.align(source, ["Hello"])
    end

    test "aligns multibyte UTF-8 text with correct byte offsets" do
      source = "café señor bueno"

      assert [%Span{text: "señor", byte_start: 6, byte_end: 12, status: :exact}] =
               Aligner.align(source, ["señor"])
    end

    test "byte offsets round-trip via binary_part" do
      source = "naïve résumé format"

      [span] = Aligner.align(source, ["résumé"])
      assert span.status == :exact

      length = span.byte_end - span.byte_start
      assert binary_part(source, span.byte_start, length) == "résumé"
    end
  end

  describe "exact matching — edge cases" do
    test "substring of a source word does not match" do
      source = "Patient is prescribed Naprosyn and prednisone for treatment."

      assert [%Span{status: :not_found}] = Aligner.align(source, ["Napro"])
    end

    test "similar word does not steal match from exact one" do
      source = "Patient is prescribed Naprosyn and prednisone for treatment."

      assert [
               %Span{text: "Naprosyn", byte_start: 22, byte_end: 30, status: :exact},
               %Span{text: "Napro", status: :not_found}
             ] = Aligner.align(source, ["Naprosyn", "Napro"])
    end

    test "matches extraction spanning a hyphen" do
      source = "Patient is prescribed Napro-syn."

      [span] = Aligner.align(source, ["Napro-syn"])
      assert span.status == :exact
      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) == "Napro-syn"
    end

    test "matches extraction with en-dash separator" do
      source = "Separated\u2013by\u2013en\u2013dashes."

      [span] = Aligner.align(source, ["en\u2013dashes"])
      assert span.status == :exact
      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) == "en\u2013dashes"
    end

    test "matches numerical extraction" do
      source = "Patient was given Ibuprofen 600mg twice daily."

      [span] = Aligner.align(source, ["Ibuprofen 600mg"])
      assert span.status == :exact
      assert span.byte_start == 18
      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) == "Ibuprofen 600mg"
    end

    test "matches extractions across sentence boundaries" do
      source = "Take Ibuprofen. Consult your doctor with concerns."

      assert [
               %Span{text: "Ibuprofen", status: :exact},
               %Span{text: "your doctor", status: :exact}
             ] = Aligner.align(source, ["Ibuprofen", "your doctor"])
    end

    test "matches multiple multi-word extractions" do
      source = "Pt was prescribed Naprosyn as needed and prednisone daily."

      spans = Aligner.align(source, ["Naprosyn", "as needed", "prednisone"])

      assert Enum.all?(spans, &(&1.status == :exact))

      Enum.each(spans, fn span ->
        extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
        assert String.downcase(extracted) == String.downcase(span.text)
      end)
    end

    test "repeated token in source falls back to fuzzy for multi-word phrase" do
      # "for" appears twice — Myers diff can't find contiguous exact match
      source = "Pt was prescribed Naprosyn for pain and prednisone for one month."

      [span] = Aligner.align(source, ["for one month"], fuzzy_threshold: 0.6)
      assert span.status == :fuzzy
      extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
      assert extracted == "for one month"
    end

    test "extractions out of source order still match independently" do
      source = "Patient with arthritis is prescribed Naprosyn."

      assert [
               %Span{text: "Naprosyn", status: :exact},
               %Span{text: "arthritis", status: :exact}
             ] = Aligner.align(source, ["Naprosyn", "arthritis"])
    end
  end

  describe "edge cases" do
    test "empty source returns not_found" do
      assert [%Span{status: :not_found}] = Aligner.align("", ["hello"])
    end

    test "empty extraction returns not_found" do
      assert [%Span{text: "", status: :not_found}] = Aligner.align("hello", [""])
    end

    test "extraction longer than source returns not_found" do
      assert [%Span{status: :not_found}] =
               Aligner.align("hi", ["this is much longer than source"])
    end
  end

  describe "fuzzy matching" do
    test "matches when most tokens overlap" do
      source = "the quick brown fox jumps"
      # LLM returned "quick brown dog" — "dog" not in source, falls to fuzzy.
      # Windows of size 3 over source words:
      #   [the,quick,brown]=2/3  [quick,brown,fox]=2/3  [brown,fox,jumps]=1/3
      # First best window wins: indices 0-2, byte_start=0 ("the"), byte_end=15 ("brown")
      extraction = "quick brown dog"

      assert [%Span{byte_start: 0, byte_end: 15, status: :fuzzy}] =
               Aligner.align(source, [extraction], fuzzy_threshold: 0.6)
    end

    test "returns not_found below threshold" do
      source = "the quick brown fox"
      extraction = "completely different words here"

      assert [%Span{status: :not_found}] = Aligner.align(source, [extraction])
    end

    test "matches with reordered words" do
      source = "Patient has severe heart problems today."

      [span] = Aligner.align(source, ["problems heart"], fuzzy_threshold: 0.6)
      assert span.status == :fuzzy
    end

    test "matches partial overlap at 75% threshold" do
      source = "Findings consistent with degenerative disc disease at L5-S1."

      [span] = Aligner.align(source, ["mild degenerative disc disease"], fuzzy_threshold: 0.75)
      assert span.status == :fuzzy

      extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
      assert extracted =~ "degenerative disc disease"
    end

    test "fails fuzzy match with low token overlap" do
      source = "Patient reports back pain and a fever."

      assert [%Span{status: :not_found}] =
               Aligner.align(source, ["headache and fever"], fuzzy_threshold: 0.75)
    end

    test "respects custom fuzzy threshold" do
      source = "the quick brown fox jumps"
      # 1 of 3 tokens match — 0.33 ratio
      extraction = "quick red cat"

      # Default threshold 0.75 → not found
      assert [%Span{status: :not_found}] = Aligner.align(source, [extraction])

      # Lowered threshold → fuzzy match
      assert [%Span{status: :fuzzy}] =
               Aligner.align(source, [extraction], fuzzy_threshold: 0.3)
    end
  end
end
