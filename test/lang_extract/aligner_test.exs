defmodule LangExtract.AlignerTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Aligner, Span}

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
end
