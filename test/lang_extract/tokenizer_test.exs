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

    test "keeps contractions as single tokens" do
      tokens = Tokenizer.tokenize("don't won't")
      words = Enum.filter(tokens, &(&1.type == :word))
      assert [%Token{text: "don't"}, %Token{text: "won't"}] = words
    end

    test "groups numbers with separators" do
      tokens = Tokenizer.tokenize("costs $1,234.56 total")
      number = Enum.find(tokens, &(&1.type == :number))
      assert %Token{text: "1,234.56", byte_start: 7, byte_end: 15} = number
    end

    test "preserves whitespace runs" do
      tokens = Tokenizer.tokenize("a  b")
      ws = Enum.find(tokens, &(&1.type == :whitespace))
      assert %Token{text: "  ", byte_start: 1, byte_end: 3} = ws
    end
  end
end
