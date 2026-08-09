defmodule LangExtract.Alignment.AlignerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.Aligner
  alias LangExtract.Span

  describe "source size" do
    # No size guard, matching upstream WordAligner: the engine aligns
    # whatever text it is handed, and cost is the caller's budget (the
    # chunked pipeline is the bounded document path). Pins the guard's
    # removal — sources of any size align without opt-in flags.
    test "book-length sources align without opt-in" do
      source = String.duplicate("word ", 60_000)

      assert [%Span{status: :exact, byte_start: 0}] = Aligner.align(source, ["word"])
    end
  end

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

    # DP places "quick brown fox" non-overlapping; fallthrough used to
    # re-claim the nested "brown" as a second :exact. Claimed intervals
    # are reserved so leftovers cannot ground inside a DP span.
    test "fallthrough does not nest an exact span inside a DP placement" do
      source = "the quick brown fox jumps"

      assert [
               %Span{text: "quick brown fox", status: :exact, byte_start: 4, byte_end: 19},
               %Span{text: "brown", status: :not_found}
             ] = Aligner.align(source, ["quick brown fox", "brown"])
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

      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) ==
               "en\u2013dashes"
    end

    test "matches numerical extraction" do
      source = "Patient was given Ibuprofen 600mg twice daily."

      [span] = Aligner.align(source, ["Ibuprofen 600mg"])
      assert span.status == :exact
      assert span.byte_start == 18

      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) ==
               "Ibuprofen 600mg"
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

    test "repeated token elsewhere in source does not prevent exact match" do
      # "for" also appears earlier in the source
      source = "Pt was prescribed Naprosyn for pain and prednisone for one month."

      [span] = Aligner.align(source, ["for one month"])
      assert span.status == :exact
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

    # LLMs normalize exotic whitespace to ASCII spaces — the same habit as
    # smart quotes. The whitespace gap must not block an exact token match.
    test "NBSP in source still grounds an ASCII-space extraction exactly" do
      source = "Take 5 mg daily"

      [span] = Aligner.align(source, ["5 mg"])

      assert span.status == :exact

      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) ==
               "5 mg"
    end

    test "formfeed page break does not split an extraction" do
      [span] = Aligner.align("hello\fworld", ["hello world"])

      assert span.status == :exact
    end

    test "CRLF source: offsets stay byte-exact past the \\r bytes" do
      source = "First line here.\r\nThe quick brown fox jumps."

      [span] = Aligner.align(source, ["quick brown fox"])

      assert span.status == :exact

      assert binary_part(source, span.byte_start, span.byte_end - span.byte_start) ==
               "quick brown fox"
    end
  end

  describe "lesser matching (partial contiguous runs)" do
    test "grounds partial overlap to the matched run's span" do
      source = "the quick brown fox jumps"
      # "dog" is not in the source; the longest contiguous run is "quick brown",
      # so the span covers exactly those tokens (bytes 4..15).
      extraction = "quick brown dog"

      assert [%Span{byte_start: 4, byte_end: 15, status: :lesser}] =
               Aligner.align(source, [extraction])
    end

    test "grounds interrupted dialogue to its prefix fragment" do
      # Model-stitched extraction: two quoted fragments merged, narrative
      # interjection dropped. Real case from the dialogue benchmark. Upstream
      # grounds the block anchored at the extraction's first token.
      source =
        ~s(“You young dog,” said the man, licking his lips, “what fat cheeks you ha’ got.”)

      extraction = "You young dog, what fat cheeks you ha’ got."

      [span] = Aligner.align(source, [extraction])
      assert span.status == :lesser

      extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
      assert extracted =~ "You young dog"
    end

    test "non-prefix shared tokens do not ground as lesser" do
      # "and"/"fever" match but no block is anchored at the extraction's
      # first token ("headache") — upstream returns not_found here too.
      source = "Patient reports back pain and a fever."

      assert [%Span{status: :not_found}] = Aligner.align(source, ["headache and fever"])
    end

    test "prefix token grounds even when the rest is absent" do
      # Only "alpha" is anchored at the extraction's first token; "beta"
      # appears in the source but can't extend a prefix-anchored block.
      source = "alpha one two three four five six beta"

      [span] = Aligner.align(source, ["alpha beta gamma"])
      assert span.status == :lesser

      extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
      assert extracted == "alpha"
    end

    test "accept_lesser: false disables partial grounding" do
      source = "alpha one two three four five six beta"

      assert [%Span{status: :not_found}] =
               Aligner.align(source, ["alpha beta gamma"], accept_lesser: false)
    end

    test "non-prefix partial overlap grounds via LCS instead" do
      # "mild" is absent, so no prefix-anchored block exists; LCS coverage
      # 3/4 = 0.75 meets the threshold and grounds the shared run.
      source = "Findings consistent with degenerative disc disease at L5-S1."

      [span] = Aligner.align(source, ["mild degenerative disc disease"])
      assert span.status == :fuzzy

      extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
      assert extracted == "degenerative disc disease"
    end

    test "reordered words return not_found (LCS is order-preserving)" do
      source = "Patient has severe heart problems today."

      assert [%Span{status: :not_found}] = Aligner.align(source, ["problems heart"])
    end
  end

  describe "LCS fuzzy matching" do
    test "no shared tokens returns not_found" do
      source = "the quick brown fox"
      extraction = "completely different words here"

      assert [%Span{status: :not_found}] = Aligner.align(source, [extraction])
    end

    test "plural variants match via light stemming" do
      source = "The cheeks were red."

      [span] = Aligner.align(source, ["cheek"])
      assert span.status == :fuzzy

      extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
      assert extracted == "cheeks"
    end

    test "coverage threshold gates acceptance when lesser is disabled" do
      source = "the quick brown fox jumps"
      # 1 of 3 tokens covered — 0.33 coverage
      extraction = "quick red cat"

      assert [%Span{status: :not_found}] =
               Aligner.align(source, [extraction], accept_lesser: false)

      assert [%Span{status: :fuzzy}] =
               Aligner.align(source, [extraction], accept_lesser: false, fuzzy_threshold: 0.3)
    end

    test "density gate rejects sparse spans" do
      source = "alpha one two three four five six beta one two three four five six gamma"

      assert [%Span{status: :not_found}] =
               Aligner.align(source, ["alpha beta gamma"], accept_lesser: false)
    end
  end

  describe "fallthrough claim reservations" do
    # The lesser block search masks claimed source tokens, so a leftover
    # whose prefix block sits inside a DP placement grounds on the next
    # free occurrence instead of giving up.
    test "lesser leftover grounds outside a DP placement" do
      source = "alpha beta x alpha beta y"

      assert [
               %Span{status: :exact, byte_start: 0, byte_end: 10},
               %Span{status: :lesser, byte_start: 13, byte_end: 23}
             ] = Aligner.align(source, ["alpha beta", "alpha beta zzz"])
    end

    # Each fallthrough hit reserves its interval for later leftovers: the
    # second extraction must skip the first leftover's reservation, not
    # just DP claims.
    test "lesser leftovers ground on successive free occurrences" do
      source = "x alpha beta y alpha beta z"

      assert [
               %Span{status: :lesser, byte_start: 2, byte_end: 12},
               %Span{status: :lesser, byte_start: 15, byte_end: 25}
             ] = Aligner.align(source, ["alpha beta zzz", "alpha beta qqq"])
    end

    test "lesser leftover with no free occurrence left is not_found" do
      source = "x alpha beta y alpha beta z"

      assert [
               %Span{status: :lesser},
               %Span{status: :lesser},
               %Span{status: :not_found}
             ] =
               Aligner.align(source, [
                 "alpha beta zzz",
                 "alpha beta qqq",
                 "alpha beta www"
               ])
    end
  end

  describe ":exact_algorithm option" do
    test ":dp (default) grounds repeated mentions to successive occurrences" do
      source = "hello world again hello world"

      assert [
               %Span{byte_start: 0, byte_end: 11, status: :exact},
               %Span{byte_start: 18, byte_end: 29, status: :exact}
             ] = Aligner.align(source, ["hello world", "hello world"])
    end

    test ":first_occurrence restores legacy first-match-wins grounding" do
      source = "hello world again hello world"

      assert [
               %Span{byte_start: 0, byte_end: 11, status: :exact},
               %Span{byte_start: 0, byte_end: 11, status: :exact}
             ] =
               Aligner.align(source, ["hello world", "hello world"],
                 exact_algorithm: :first_occurrence
               )
    end
  end
end
