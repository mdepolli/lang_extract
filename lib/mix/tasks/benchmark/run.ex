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

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [task: :string, corpus: :string, out: :string, document: :string]
      )

    task_name = opts[:task] || Mix.raise("Missing --task argument")
    corpus_dir = opts[:corpus] || @default_corpus
    out_dir = opts[:out] || @default_out

    task_def = load_task(task_name)
    client = build_client()
    template = build_template(task_def)
    corpus_files = corpus_files!(corpus_dir, opts[:document])

    run_dir = create_run_dir!(out_dir, task_name)

    Mix.shell().info("Running task '#{task_name}' on #{length(corpus_files)} documents...")

    meta = run_meta()

    Enum.each(corpus_files, fn file ->
      run_document(file, client, template, task_name, run_dir, meta)
    end)

    update_latest_symlink(out_dir, task_name, run_dir)

    Mix.shell().info("\nResults written to #{run_dir}/")
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
  defp run_document(file, client, template, task_name, run_dir, meta) do
    slug = Path.basename(file, ".txt")

    result =
      try do
        extract_document(file, slug, client, template, task_name)
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

  defp extract_document(file, slug, client, template, task_name) do
    source = File.read!(file)
    Mix.shell().info("  #{slug} (#{byte_size(source)} bytes)...")

    {elapsed_us, run_result} =
      :timer.tc(fn ->
        LangExtract.run(client, source, template,
          max_chunk_chars: @max_chunk_chars,
          max_concurrency: 2
        )
      end)

    document_result(slug, task_name, run_result, div(elapsed_us, 1000))
  end

  @doc false
  def document_result(slug, task_name, {:ok, {spans, errors}}, elapsed_ms) do
    %{
      "source" => slug,
      "task" => task_name,
      "library" => "elixir",
      "extractions" => Enum.map(spans, &Serializer.span_to_map/1),
      "timing" => %{"total_ms" => elapsed_ms},
      "errors" => Enum.map(errors, &chunk_error_to_map/1)
    }
  end

  def document_result(slug, task_name, {:error, reason}, _elapsed_ms) do
    failure_result(slug, task_name, inspect(reason))
  end

  defp failure_result(slug, task_name, reason) do
    %{
      "source" => slug,
      "task" => task_name,
      "library" => "elixir",
      "extractions" => [],
      "timing" => nil,
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
