defmodule Mix.Tasks.Benchmark.Run do
  # Repo-internal tool (excluded from the hex package); hidden from
  # generated docs — it needs the local benchmark/ corpus to run.
  @moduledoc false
  @shortdoc "Run extraction benchmark"

  use Mix.Task

  alias LangExtract.{Extraction, Pipeline.ChunkError, Prompt, Serializer}

  @default_corpus "benchmark/corpus"
  @default_out "benchmark/results/elixir"

  @model "claude-sonnet-5"
  @max_tokens 8192
  @max_chunk_chars 1000

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    do_run(args, &live_extract/2)
  end

  # Seam for tests: the extractor receives (source, template) and returns
  # LangExtract.run/4's shape, so everything around the API call — arg
  # parsing, corpus discovery, run-dir creation, result files, symlink
  # rotation — is exercisable without network access.
  @doc false
  def do_run(args, extractor) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [task: :string, corpus: :string, out: :string, document: :string]
      )

    task_name = opts[:task] || Mix.raise("Missing --task argument")
    corpus_dir = opts[:corpus] || @default_corpus
    out_dir = opts[:out] || @default_out

    task_def = load_task(task_name)
    template = build_template(task_def)
    corpus_files = corpus_files!(corpus_dir, opts[:document])

    run_dir = create_run_dir!(out_dir, task_name)

    Mix.shell().info("Running task '#{task_name}' on #{length(corpus_files)} documents...")

    meta = run_meta()

    Enum.each(corpus_files, fn file ->
      run_document(file, extractor, template, task_name, run_dir, meta)
    end)

    update_latest_symlink(out_dir, task_name, run_dir)

    Mix.shell().info("\nResults written to #{run_dir}/")
  end

  defp live_extract(source, template) do
    LangExtract.run(build_client(), source, template,
      max_chunk_chars: @max_chunk_chars,
      max_concurrency: 2
    )
  end

  defp corpus_files!(corpus_dir, nil) do
    case corpus_dir |> Path.join("*.txt") |> Path.wildcard() |> Enum.sort() do
      [] -> Mix.raise("No corpus files found in #{corpus_dir}")
      files -> files
    end
  end

  defp corpus_files!(corpus_dir, slug) do
    path = Path.join(corpus_dir, "#{slug}.txt")

    if File.exists?(path) do
      [path]
    else
      Mix.raise("Corpus document not found: #{path}")
    end
  end

  defp create_run_dir!(out_dir, task_name) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    run_dir = Path.join(out_dir, "#{task_name}_#{timestamp}")
    File.mkdir_p!(out_dir)

    case File.mkdir(run_dir) do
      :ok -> run_dir
      {:error, :eexist} -> Mix.raise("Run directory already exists: #{run_dir}")
      {:error, reason} -> Mix.raise("Could not create #{run_dir}: #{:file.format_error(reason)}")
    end
  end

  # One document's failure must not abandon the rest of the corpus run —
  # every document gets a result file, error or not.
  defp run_document(file, extractor, template, task_name, run_dir, meta) do
    slug = Path.basename(file, ".txt")

    result =
      try do
        extract_document(file, slug, extractor, template, task_name)
      rescue
        e -> failure_result(slug, task_name, Exception.message(e))
      end

    result = Map.put(result, "meta", meta)
    report_document(result)
    File.write!(Path.join(run_dir, "#{slug}.json"), Jason.encode!(result, pretty: true))
  end

  defp run_meta do
    %{
      "runner_commit" => git_commit(),
      "library_version" => to_string(Application.spec(:lang_extract, :vsn)),
      "model" => @model,
      "max_tokens" => @max_tokens,
      "max_chunk_chars" => @max_chunk_chars
    }
  end

  # A stamp from uncommitted code is misleading — mark it.
  defp git_commit do
    with {sha, 0} <- System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true),
         {status, 0} <- System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      suffix = if String.trim(status) == "", do: "", else: "-dirty"
      String.trim(sha) <> suffix
    else
      _ -> "unknown"
    end
  end

  defp extract_document(file, slug, extractor, template, task_name) do
    source = File.read!(file)
    Mix.shell().info("  #{slug} (#{byte_size(source)} bytes)...")

    {elapsed_us, run_result, requests} =
      with_request_collection(slug, fn -> extractor.(source, template) end)

    elapsed_ms = div(elapsed_us, 1000)
    document_result(slug, task_name, run_result, elapsed_ms, usage_block(requests, elapsed_ms))
  end

  # Documents run sequentially, so a per-document handler window cleanly
  # scopes the request events to this document. The handler runs in the
  # chunk task processes; a public ETS table (no process to supervise)
  # collects concurrent inserts, ordered by a monotonic counter.
  defp with_request_collection(slug, fun) do
    table = :ets.new(:benchmark_requests, [:public, :ordered_set])
    handler_id = "benchmark-usage-#{slug}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:lang_extract, :request, :stop],
      fn _event, measurements, metadata, _config ->
        :ets.insert(table, {System.unique_integer([:monotonic]), measurements, metadata})
      end,
      nil
    )

    try do
      {elapsed_us, run_result} = :timer.tc(fun)

      requests =
        table
        |> :ets.tab2list()
        |> Enum.map(fn {_order, measurements, metadata} -> {measurements, metadata} end)

      {elapsed_us, run_result, requests}
    after
      :telemetry.detach(handler_id)
      :ets.delete(table)
    end
  end

  defp usage_block(requests, elapsed_ms) do
    input = requests |> Enum.map(fn {meas, _meta} -> meas[:input_tokens] || 0 end) |> Enum.sum()
    output = requests |> Enum.map(fn {meas, _meta} -> meas[:output_tokens] || 0 end) |> Enum.sum()

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "output_tokens_per_sec" => tokens_per_sec(output, elapsed_ms),
      "requests" => Enum.map(requests, &request_entry/1)
    }
  end

  defp tokens_per_sec(_output, 0), do: nil
  defp tokens_per_sec(output, elapsed_ms), do: Float.round(output * 1000 / elapsed_ms, 1)

  defp request_entry({measurements, metadata}) do
    %{
      "ms" => System.convert_time_unit(measurements.duration, :native, :millisecond),
      "input_tokens" => measurements[:input_tokens],
      "output_tokens" => measurements[:output_tokens],
      "status" => to_string(metadata.status)
    }
  end

  @doc false
  def document_result(slug, task_name, run_result, elapsed_ms, usage \\ nil)

  def document_result(slug, task_name, {:ok, {spans, errors}}, elapsed_ms, usage) do
    %{
      "source" => slug,
      "task" => task_name,
      "library" => "elixir",
      "extractions" => Enum.map(spans, &Serializer.span_to_map/1),
      "timing" => %{"total_ms" => elapsed_ms},
      "usage" => usage,
      "errors" => Enum.map(errors, &chunk_error_to_map/1)
    }
  end

  def document_result(slug, task_name, {:error, reason}, _elapsed_ms, _usage) do
    failure_result(slug, task_name, inspect(reason))
  end

  defp failure_result(slug, task_name, reason) do
    %{
      "source" => slug,
      "task" => task_name,
      "library" => "elixir",
      "extractions" => [],
      "timing" => nil,
      "usage" => nil,
      "errors" => [%{"byte_start" => nil, "byte_end" => nil, "reason" => reason}]
    }
  end

  defp report_document(%{"timing" => nil, "errors" => [%{"reason" => reason}]}) do
    Mix.shell().error("    ERROR: #{reason}")
  end

  defp report_document(result) do
    extractions = length(result["extractions"])
    errors = length(result["errors"])
    ms = result["timing"]["total_ms"]

    if errors == 0 do
      Mix.shell().info("    #{extractions} extractions in #{ms}ms")
    else
      Mix.shell().error(
        "    #{errors} chunk error(s), #{extractions} partial extractions in #{ms}ms"
      )
    end
  end

  # A failed rotation shouldn't crash an otherwise successful run.
  defp update_latest_symlink(out_dir, task_name, run_dir) do
    link = Path.join(out_dir, "#{task_name}_latest")
    _ = File.rm(link)

    case File.ln_s(Path.basename(run_dir), link) do
      :ok ->
        Mix.shell().info("Symlink updated: #{link} -> #{Path.basename(run_dir)}")

      {:error, reason} ->
        Mix.shell().error("Warning: could not update #{link}: #{:file.format_error(reason)}")
    end
  end

  defp load_task(name) do
    path = Path.join("benchmark/tasks", "#{name}.json")

    with {:ok, content} <- File.read(path),
         {:ok, task_def} <- Jason.decode(content) do
      task_def
    else
      {:error, reason} -> Mix.raise("Could not load task #{path}: #{inspect(reason)}")
    end
  end

  defp build_client do
    api_key = System.get_env("ANTHROPIC_API_KEY") || Mix.raise("ANTHROPIC_API_KEY not set")

    LangExtract.new(:claude,
      api_key: api_key,
      model: @model,
      max_tokens: @max_tokens
    )
  end

  defp build_template(task_def) do
    examples =
      Enum.map(task_def["examples"], fn ex ->
        extractions =
          Enum.map(ex["extractions"], fn e ->
            %Extraction{
              class: e["class"],
              text: e["text"],
              attributes: e["attributes"] || %{}
            }
          end)

        %Prompt.ExampleData{text: ex["text"], extractions: extractions}
      end)

    %Prompt.Template{description: task_def["description"], examples: examples}
  end

  defp chunk_error_to_map(%ChunkError{} = err) do
    %{
      "byte_start" => err.byte_start,
      "byte_end" => err.byte_end,
      "reason" => inspect(err.reason)
    }
  end
end
