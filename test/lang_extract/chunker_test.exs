defmodule LangExtract.ChunkerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Chunker

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
