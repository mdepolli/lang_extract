defmodule LangExtract.ChunkerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Chunker

  describe "chunk/2" do
    test "text within max_chunk_chars returns single chunk" do
      chunks = Chunker.chunk("Hello world.", max_chunk_chars: 100)
      assert length(chunks) == 1
      assert hd(chunks).text == "Hello world."
      assert hd(chunks).byte_start == 0
    end

    test "packs multiple sentences into chunks" do
      text = "First sentence. Second sentence. Third sentence. Fourth sentence."
      chunks = Chunker.chunk(text, max_chunk_chars: 35)
      assert length(chunks) >= 2
      reconstructed = Enum.map_join(chunks, "", & &1.text)
      assert reconstructed == text
    end

    # Packing counts characters (String.length) while offsets count bytes
    # (byte_size) — this pins that mixed accounting with text where the two
    # disagree at every chunk boundary.
    test "multi-byte text at chunk boundaries: no split codepoints, byte offsets faithful" do
      text =
        "Ahab saw the 🐳 breach. Café déjà vu — again. " <>
          "日本語のテキストです。 Ça alors, señor Ahab! " <>
          "The 🐳🐳 returned at dawn. Fin de l'histoire."

      for max_chars <- [20, 25, 30, 40, 60] do
        chunks = Chunker.chunk(text, max_chunk_chars: max_chars)

        for chunk <- chunks do
          assert String.valid?(chunk.text), "split codepoint at max_chars=#{max_chars}"

          assert binary_part(text, chunk.byte_start, chunk.byte_end - chunk.byte_start) ==
                   chunk.text,
                 "byte offsets drifted at max_chars=#{max_chars}"
        end

        assert Enum.map_join(chunks, "", & &1.text) == text
      end
    end

    test "oversized multi-byte sentence hard-splits at token boundaries" do
      text = "🐳🐳🐳 café déjà 日本語 señor — one very long sentence indeed."

      chunks = Chunker.chunk(text, max_chunk_chars: 10)

      assert length(chunks) > 1

      for chunk <- chunks do
        assert String.valid?(chunk.text)

        assert binary_part(text, chunk.byte_start, chunk.byte_end - chunk.byte_start) ==
                 chunk.text
      end

      assert Enum.map_join(chunks, "", & &1.text) == text
    end

    test "boundary-free text is hard-split within the budget" do
      # No sentence boundaries at all — the log/minified-content case.
      text = Enum.map_join(1..60, " ", &"word#{&1}")

      chunks = Chunker.chunk(text, max_chunk_chars: 50)

      assert length(chunks) > 5

      for chunk <- chunks do
        assert String.length(chunk.text) <= 50

        assert binary_part(text, chunk.byte_start, chunk.byte_end - chunk.byte_start) ==
                 chunk.text
      end

      assert Enum.map_join(chunks, "", & &1.text) == text
    end

    test "a single token longer than the budget stays whole" do
      text = String.duplicate("x", 60)

      [chunk] = Chunker.chunk(text, max_chunk_chars: 25)
      assert chunk.text == text
    end

    test "empty text returns empty list" do
      assert Chunker.chunk("", max_chunk_chars: 100) == []
    end

    test "byte_start offsets are correct for each chunk" do
      text = "Short. Also short. Third one here."
      chunks = Chunker.chunk(text, max_chunk_chars: 20)

      for chunk <- chunks do
        assert binary_part(text, chunk.byte_start, byte_size(chunk.text)) == chunk.text
      end
    end

    test "single sentence without punctuation is hard-split within the budget" do
      text = "this is a long run on sentence without any punctuation at all"
      chunks = Chunker.chunk(text, max_chunk_chars: 20)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(String.length(&1.text) <= 20))
      assert Enum.map_join(chunks, "", & &1.text) == text
    end

    test "chunks cover entire source text" do
      text = "Hello world. How are you? I am fine. Thanks for asking!"
      chunks = Chunker.chunk(text, max_chunk_chars: 25)
      reconstructed = Enum.map_join(chunks, "", & &1.text)
      assert reconstructed == text
    end

    test "handles multibyte UTF-8 text with correct byte offsets" do
      # café = 5 bytes (é is 2 bytes), señor = 6 bytes (ñ is 2 bytes)
      text = "Café is great. Señor drinks café."
      chunks = Chunker.chunk(text, max_chunk_chars: 20)

      for chunk <- chunks do
        assert binary_part(text, chunk.byte_start, byte_size(chunk.text)) == chunk.text
      end

      reconstructed = Enum.map_join(chunks, "", & &1.text)
      assert reconstructed == text
    end

    test "text exactly at max_chunk_chars boundary" do
      text = "Hello. World."
      chunks = Chunker.chunk(text, max_chunk_chars: String.length(text))
      assert length(chunks) == 1
      assert hd(chunks).text == text
    end
  end

  describe "find_sentences/1" do
    test "splits on period" do
      sentences = Chunker.find_sentences("Hello world. Goodbye world.")
      assert length(sentences) == 2
      assert Enum.at(sentences, 0) =~ "Hello world."
      assert Enum.at(sentences, 1) =~ "Goodbye world."
    end

    test "splits on ! and ?" do
      sentences = Chunker.find_sentences("What? Yes! OK.")
      assert length(sentences) == 3
    end

    test "does not split on abbreviations" do
      sentences = Chunker.find_sentences("Dr. Smith is here. He is nice.")
      assert length(sentences) == 2
      assert String.contains?(Enum.at(sentences, 0), "Dr. Smith")
    end

    test "consumes trailing closing punctuation into same sentence" do
      sentences = Chunker.find_sentences(~s(He said "hello." Then left.))
      assert length(sentences) == 2
      assert String.contains?(Enum.at(sentences, 0), ~s("hello."))
    end

    test "newline followed by uppercase starts new sentence" do
      sentences = Chunker.find_sentences("First line\nSecond line")
      assert length(sentences) == 2
    end

    test "newline followed by lowercase does not start new sentence" do
      sentences = Chunker.find_sentences("first line\nsecond line")
      assert length(sentences) == 1
    end

    test "empty text returns empty list" do
      assert Chunker.find_sentences("") == []
    end

    test "multiple abbreviations in sequence" do
      sentences = Chunker.find_sentences("Mr. Dr. Smith arrived. Then left.")
      assert length(sentences) == 2
      assert hd(sentences) =~ "Mr. Dr. Smith arrived."
    end

    test "no sentence-ending punctuation returns one sentence" do
      text = "This is just some text without any sentence ending"
      sentences = Chunker.find_sentences(text)
      assert length(sentences) == 1
      assert hd(sentences) == text
    end

    test "sentences concatenated equal original text" do
      text = "Hello world. Goodbye world. How are you?"
      sentences = Chunker.find_sentences(text)
      assert Enum.join(sentences) == text
    end
  end
end
