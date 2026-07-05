defmodule Mix.Tasks.Benchmark.RunTest do
  # async: false — do_run tests swap the global Mix shell.
  use ExUnit.Case, async: false

  alias LangExtract.Alignment.Span
  alias LangExtract.Pipeline.ChunkError
  alias Mix.Tasks.Benchmark.Run

  @span %Span{
    text: "fox",
    byte_start: 16,
    byte_end: 19,
    status: :exact,
    class: "animal",
    attributes: %{}
  }

  describe "do_run/2" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      previous_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(previous_shell) end)

      corpus = Path.join(tmp_dir, "corpus")
      out = Path.join(tmp_dir, "out")
      File.mkdir_p!(corpus)
      File.write!(Path.join(corpus, "alpha.txt"), "the quick brown fox")
      File.write!(Path.join(corpus, "beta.txt"), "hello world")

      %{corpus: corpus, out: out}
    end

    defp ok_extractor(source, _template) do
      {:ok, {[%Span{@span | text: source |> String.split() |> List.last()}], []}}
    end

    defp run_args(corpus, out, extra \\ []) do
      ["--task", "ner", "--corpus", corpus, "--out", out] ++ extra
    end

    test "writes one schema-complete result file per corpus document", %{
      corpus: corpus,
      out: out
    } do
      Run.do_run(run_args(corpus, out), &ok_extractor/2)

      [run_dir] = out |> Path.join("ner_2*") |> Path.wildcard()

      for slug <- ["alpha", "beta"] do
        result = run_dir |> Path.join("#{slug}.json") |> File.read!() |> Jason.decode!()

        assert result["source"] == slug
        assert result["task"] == "ner"
        assert result["library"] == "elixir"
        assert [%{"status" => "exact"}] = result["extractions"]
        assert %{"total_ms" => ms} = result["timing"]
        assert is_integer(ms)
        assert result["errors"] == []
        assert %{"runner_commit" => commit, "model" => _} = result["meta"]
        assert commit != ""
      end
    end

    test "maintains the {task}_latest symlink, replacing a stale one", %{
      corpus: corpus,
      out: out
    } do
      File.mkdir_p!(out)
      link = Path.join(out, "ner_latest")
      File.ln_s!("ner_gone_stale", link)

      Run.do_run(run_args(corpus, out), &ok_extractor/2)

      [run_dir] = out |> Path.join("ner_2*") |> Path.wildcard()
      assert File.read_link!(link) == Path.basename(run_dir)
    end

    test "a raising document is isolated: failure entry written, run continues", %{
      corpus: corpus,
      out: out
    } do
      extractor = fn source, _template ->
        if source =~ "fox", do: raise("boom on alpha"), else: {:ok, {[@span], []}}
      end

      Run.do_run(run_args(corpus, out), extractor)

      [run_dir] = out |> Path.join("ner_2*") |> Path.wildcard()

      alpha = run_dir |> Path.join("alpha.json") |> File.read!() |> Jason.decode!()
      assert alpha["timing"] == nil
      assert [%{"byte_start" => nil, "byte_end" => nil, "reason" => reason}] = alpha["errors"]
      assert reason =~ "boom on alpha"

      beta = run_dir |> Path.join("beta.json") |> File.read!() |> Jason.decode!()
      assert beta["errors"] == []
    end

    test "collects request telemetry into the usage block", %{corpus: corpus, out: out} do
      emitting_extractor = fn source, _template ->
        # Nonzero elapsed time, so output_tokens_per_sec is computable.
        Process.sleep(10)

        :telemetry.execute(
          [:lang_extract, :request, :stop],
          %{
            duration: System.convert_time_unit(1500, :millisecond, :native),
            input_tokens: 100,
            output_tokens: 40
          },
          %{provider: :claude, model: "test", status: 200}
        )

        :telemetry.execute(
          [:lang_extract, :request, :stop],
          %{duration: System.convert_time_unit(800, :millisecond, :native)},
          %{provider: :claude, model: "test", status: 429}
        )

        {:ok, {[%Span{@span | text: source |> String.split() |> List.last()}], []}}
      end

      Run.do_run(run_args(corpus, out, ["--document", "alpha"]), emitting_extractor)

      [run_dir] = out |> Path.join("ner_2*") |> Path.wildcard()
      result = run_dir |> Path.join("alpha.json") |> File.read!() |> Jason.decode!()

      usage = result["usage"]
      assert usage["input_tokens"] == 100
      assert usage["output_tokens"] == 40
      assert is_float(usage["output_tokens_per_sec"])

      assert [first, second] = usage["requests"]
      assert first["ms"] == 1500
      assert first["input_tokens"] == 100
      assert first["status"] == "200"
      assert second["ms"] == 800
      assert second["input_tokens"] == nil
      assert second["status"] == "429"
    end

    test "an extractor emitting no telemetry yields a zeroed usage block", %{
      corpus: corpus,
      out: out
    } do
      Run.do_run(run_args(corpus, out, ["--document", "beta"]), &ok_extractor/2)

      [run_dir] = out |> Path.join("ner_2*") |> Path.wildcard()
      result = run_dir |> Path.join("beta.json") |> File.read!() |> Jason.decode!()

      assert result["usage"]["input_tokens"] == 0
      assert result["usage"]["output_tokens"] == 0
      assert result["usage"]["requests"] == []
    end

    test "--document restricts the run to one corpus file", %{corpus: corpus, out: out} do
      Run.do_run(run_args(corpus, out, ["--document", "beta"]), &ok_extractor/2)

      [run_dir] = out |> Path.join("ner_2*") |> Path.wildcard()
      assert run_dir |> Path.join("beta.json") |> File.exists?()
      refute run_dir |> Path.join("alpha.json") |> File.exists?()
    end

    test "raises on missing --task and unknown --document", %{corpus: corpus, out: out} do
      assert_raise Mix.Error, ~r/Missing --task/, fn ->
        Run.do_run(["--corpus", corpus, "--out", out], &ok_extractor/2)
      end

      assert_raise Mix.Error, ~r/not found/, fn ->
        Run.do_run(run_args(corpus, out, ["--document", "nope"]), &ok_extractor/2)
      end
    end
  end

  describe "document_result/4" do
    test "clean success has empty errors list and timing" do
      result = Run.document_result("slug", "dialogue", {:ok, {[@span], []}}, 1200)

      assert result["source"] == "slug"
      assert result["task"] == "dialogue"
      assert result["library"] == "elixir"
      assert [%{"text" => "fox", "status" => "exact"}] = result["extractions"]
      assert result["timing"] == %{"total_ms" => 1200}
      assert result["errors"] == []
    end

    test "partial success carries chunk errors alongside extractions" do
      error = %ChunkError{byte_start: 0, byte_end: 1000, reason: :rate_limited}
      result = Run.document_result("slug", "ner", {:ok, {[@span], [error]}}, 900)

      assert length(result["extractions"]) == 1
      assert result["timing"] == %{"total_ms" => 900}

      assert result["errors"] == [
               %{"byte_start" => 0, "byte_end" => 1000, "reason" => ":rate_limited"}
             ]
    end

    test "total failure has null timing and a single null-offset error" do
      result = Run.document_result("slug", "ner", {:error, :timeout}, 500)

      assert result["extractions"] == []
      assert result["timing"] == nil

      assert result["errors"] == [
               %{"byte_start" => nil, "byte_end" => nil, "reason" => ":timeout"}
             ]
    end

    test "result encodes to JSON" do
      assert {:ok, _} =
               "slug"
               |> Run.document_result("dialogue", {:ok, {[@span], []}}, 1)
               |> Jason.encode()
    end
  end
end
