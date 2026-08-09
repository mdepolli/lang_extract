defmodule LangExtract.Alignment.AlignerDifferentialTest do
  @moduledoc """
  Differential tests: the production aligner against the frozen
  line-comparable baseline in test support.

  The baseline is the pre-reshape implementation the parity fixtures tied
  to upstream, with the one deliberate behavior change since (the
  lesser-only claim narrowing) re-applied in its old shape; these tests
  hold every future aligner reshape to it on a generated corpus dense
  enough to hit phase interactions no hand-written fixture samples (see
  the trust-chain doctrine in CLAUDE.md).
  """
  use ExUnit.Case, async: true

  alias LangExtract.Alignment.Aligner
  alias LangExtract.Test.AlignerBaseline

  # Small pools engineered for collisions: repeated words force the
  # occurrence DP and claims; case, plural, and multibyte variants push
  # extractions off the exact path into lesser and LCS.
  @words ~w(big cat sat the quick brown fox Ahab Queequeg alpha beta café 東京 42)
  @gaps [" ", " ", " ", ". ", ", ", "! ", "\n", " — ", "; ", "\nThe ", "\nnext "]

  # Option sweeps cover every config-sensitive gate: the LCS threshold
  # (including the 0.28 float knife-edge), density, the lesser toggle,
  # and the claim-free legacy algorithm.
  @configs [
    [],
    [accept_lesser: false],
    [fuzzy_threshold: 0.9],
    [fuzzy_threshold: 0.28],
    [min_density: 0.6],
    [exact_algorithm: :first_occurrence]
  ]

  defp gen_case(seed) do
    :rand.seed(:exsss, {seed, 271, 828})

    words = Enum.map(1..Enum.random(8..30), fn _ -> Enum.random(@words) end)
    source = Enum.map_join(words, fn word -> word <> Enum.random(@gaps) end)
    extractions = Enum.map(1..Enum.random(1..6), fn _ -> gen_extraction(words) end)

    {source, extractions}
  end

  # Extractions are n-grams of the source, possibly mutated: verbatim
  # (DP/exact), pluralized or case-flipped tails (stemming, LCS),
  # paraphrase suffixes (lesser prefix anchoring), or absent phrases
  # (:not_found). Model output order is arbitrary, so no sorting.
  defp gen_extraction(words) do
    count = length(words)
    start = :rand.uniform(count) - 1
    len = min(:rand.uniform(4), count - start)
    phrase = words |> Enum.slice(start, len) |> Enum.join(" ")

    case :rand.uniform(6) do
      1 -> phrase <> "s"
      2 -> String.capitalize(phrase)
      3 -> phrase <> " vanished"
      4 -> "missing entirely #{:rand.uniform(1000)}"
      _ -> phrase
    end
  end

  test "generated corpus: align/3 matches the baseline across configs" do
    for seed <- 1..60, config <- @configs do
      {source, extractions} = gen_case(seed)

      assert Aligner.align(source, extractions, config) ==
               AlignerBaseline.align(source, extractions, config),
             "align/3 diverged from baseline at seed #{seed}, config #{inspect(config)}"
    end
  end

  # Shapes the random mix underweights: contested and nested overlaps
  # (the claim-narrowing battleground), repeat-heavy DP chains, and the
  # degenerate empties.
  test "targeted shapes match the baseline" do
    cases = [
      {"big cat sat big cat", ["big cat", "cat sat"]},
      {"the cat sat", ["cat", "the cat sat"]},
      {"Patient has type 2 diabetes.", ["type 2 diabetes", "diabetes"]},
      {"Queequeg smiled. Queequeg nodded.", ["Queequeg", "Queequeg", "Queequeg vanished"]},
      {"spam eggs spam eggs spam", ["spam", "eggs", "spam", "eggs", "spam"]},
      {"word", ["much longer than the source itself"]},
      {"", ["anything"]},
      {"some source text", []}
    ]

    for {source, extractions} <- cases, config <- @configs do
      assert Aligner.align(source, extractions, config) ==
               AlignerBaseline.align(source, extractions, config)
    end
  end
end
