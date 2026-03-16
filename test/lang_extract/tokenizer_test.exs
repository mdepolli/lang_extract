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

    test "handles multibyte UTF-8 characters with correct byte offsets" do
      # é is 2 bytes in UTF-8, ñ is 2 bytes
      tokens = Tokenizer.tokenize("café señor")

      cafe = Enum.find(tokens, &(&1.text == "café"))
      # c(1) a(1) f(1) é(2) = 5 bytes
      assert %Token{byte_start: 0, byte_end: 5} = cafe

      senor = Enum.find(tokens, &(&1.text == "señor"))
      # s(1) e(1) ñ(2) o(1) r(1) = 6 bytes
      assert %Token{byte_start: 6, byte_end: 12} = senor
    end

    test "byte offsets can round-trip via binary_part" do
      source = "café señor"
      tokens = Tokenizer.tokenize(source)

      for token <- tokens do
        length = token.byte_end - token.byte_start
        assert binary_part(source, token.byte_start, length) == token.text
      end
    end

    test "handles CJK characters (3 bytes each in UTF-8)" do
      # 你 = 3 bytes, 好 = 3 bytes, space = 1 byte, 世 = 3 bytes, 界 = 3 bytes
      tokens = Tokenizer.tokenize("你好 世界")

      hello = Enum.find(tokens, &(&1.text == "你好"))
      assert %Token{byte_start: 0, byte_end: 6} = hello

      world = Enum.find(tokens, &(&1.text == "世界"))
      assert %Token{byte_start: 7, byte_end: 13} = world
    end

    test "handles emoji (4 bytes in UTF-8)" do
      # 🎉 = 4 bytes
      source = "hello 🎉 world"
      tokens = Tokenizer.tokenize(source)

      emoji = Enum.find(tokens, &(&1.text == "🎉"))
      assert %Token{byte_start: 6, byte_end: 10} = emoji

      world = Enum.find(tokens, &(&1.text == "world"))
      assert %Token{byte_start: 11, byte_end: 16} = world
    end
  end
end
