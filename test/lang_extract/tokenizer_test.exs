defmodule LangExtract.TokenizerTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Token, Tokenizer}

  describe "tokenize/1" do
    test "splits words and punctuation with correct byte offsets" do
      tokens = Tokenizer.tokenize("Hello, world!")

      assert [
               %Token{text: "Hello", type: :word, byte_start: 0, byte_end: 5},
               %Token{text: ",", type: :punctuation, byte_start: 5, byte_end: 6},
               %Token{text: " ", type: :whitespace, byte_start: 6, byte_end: 7},
               %Token{text: "world", type: :word, byte_start: 7, byte_end: 12},
               %Token{text: "!", type: :punctuation, byte_start: 12, byte_end: 13}
             ] = tokens
    end

    test "empty string returns empty list" do
      assert [] = Tokenizer.tokenize("")
    end
  end
end
