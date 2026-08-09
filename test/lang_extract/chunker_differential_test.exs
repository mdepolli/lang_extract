defmodule LangExtract.ChunkerDifferentialTest do
  @moduledoc """
  Differential tests: the production chunker against the frozen
  line-comparable baseline in test support.

  The baseline is the implementation the parity fixtures tied to upstream;
  these tests tie the boundary-precompute rewrite to the baseline on a
  generated corpus dense enough to hit rule interactions no hand-written
  fixture samples (see the trust-chain doctrine in CLAUDE.md).
  """
  use ExUnit.Case, async: true

  alias LangExtract.Chunker
  alias LangExtract.Test.ChunkerBaseline

  # Fragment pools chosen to hit every boundary rule and their
  # interactions: terminators (incl. CJK and "..." runs), abbreviations
  # ("Dr" + "." — and "Dr" mid-sentence), closing-punctuation runs after
  # terminators, line breaks followed by lowercase / uppercase / digit /
  # quote starts, CRLF, and multibyte text.
  # incomprehensibilities exceeds the small budgets, exercising the
  # oversized-token path against random contexts; Mrs/Ms/St round out the
  # abbreviation list; ！？। are the otherwise-untested terminator regex
  # alternatives (fullwidth + Devanagari danda), » } the untested closers.
  @words ~w(alpha Beta gamma DELTA the quick brown fox jumps 42 3.14 café 東京
            Dr Mr Prof Mrs Ms St incomprehensibilities)
  @terminators [".", "!", "?", "。", "...", "?!", "！", "？", "।"]
  @closers [~s("), "'", ")", "]", "”", "’", ~s|")|, "’”", "»", "}"]
  @separators [" ", "  ", "\n", "\r\n", "\n\n", " \n ", "\r", "\t"]
  # 3 makes nearly every token oversized; the rest sweep packing regimes.
  @budgets [3, 17, 64, 250, 1000]

  defp gen_text(seed, fragments) do
    :rand.seed(:exsss, {seed, 1721, 2903})

    1..fragments
    |> Enum.map(fn _ -> gen_fragment() end)
    |> IO.iodata_to_binary()
  end

  defp gen_fragment do
    word = Enum.random(@words)
    terminator = if :rand.uniform() < 0.35, do: Enum.random(@terminators), else: ""
    closer = if terminator != "" and :rand.uniform() < 0.4, do: Enum.random(@closers), else: ""
    [word, terminator, closer, Enum.random(@separators)]
  end

  test "generated corpus: chunk/2 matches the baseline across budgets" do
    for seed <- 1..50, budget <- @budgets do
      text = gen_text(seed, 300)

      assert Chunker.chunk(text, max_chunk_chars: budget) ==
               ChunkerBaseline.chunk(text, max_chunk_chars: budget),
             "chunk/2 diverged from baseline at seed #{seed}, budget #{budget}"
    end
  end

  test "generated corpus: find_sentences/1 matches the baseline" do
    for seed <- 51..100 do
      text = gen_text(seed, 300)

      assert Chunker.find_sentences(text) == ChunkerBaseline.find_sentences(text),
             "find_sentences/1 diverged from baseline at seed #{seed}"
    end
  end

  # Shapes the random mix underweights: no boundaries at all (the
  # quadratic case the rewrite exists for), a document that is one giant
  # token, terminator/closer walls, and the empty document.
  test "targeted shapes match the baseline" do
    boundary_free = Enum.map_join(1..5_000, " ", fn _ -> "word" end)
    one_giant_token = String.duplicate("x", 5_000)
    terminator_wall = String.duplicate(". ", 2_000)
    closer_wall = "End." <> String.duplicate(~s(”), 3_000) <> " lower next"
    crlf_prose = Enum.map_join(1..500, "\r\n", fn i -> "Line number #{i} ends here." end)
    whitespace_only = "   \n\t  "

    for text <- [
          boundary_free,
          one_giant_token,
          terminator_wall,
          closer_wall,
          crlf_prose,
          whitespace_only,
          ""
        ],
        budget <- @budgets do
      assert Chunker.chunk(text, max_chunk_chars: budget) ==
               ChunkerBaseline.chunk(text, max_chunk_chars: budget)

      assert Chunker.find_sentences(text) == ChunkerBaseline.find_sentences(text)
    end
  end
end
