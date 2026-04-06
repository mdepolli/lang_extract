defmodule Mix.Tasks.Benchmark.Run do
  @moduledoc "Run LangExtract benchmark against corpus texts."
  @shortdoc "Run extraction benchmark"

  use Mix.Task

  alias LangExtract.{Pipeline.ChunkError, Pipeline.Extraction, Prompt}

  @default_corpus "benchmark/corpus"
  @default_out "benchmark/results/elixir"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [task: :string, corpus: :string, out: :string, document: :string]
      )

    task_name = opts[:task] || raise "Missing --task argument"
    corpus_dir = opts[:corpus] || @default_corpus
    out_dir = opts[:out] || @default_out

    task_def = load_task(task_name)
    client = build_client()
    template = build_template(task_def)

    corpus_files =
      case opts[:document] do
        nil -> Path.wildcard(Path.join(corpus_dir, "*.txt")) |> Enum.sort()
        slug -> [Path.join(corpus_dir, "#{slug}.txt")]
      end

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    run_dir = Path.join(out_dir, "#{task_name}_#{timestamp}")
    File.mkdir_p!(run_dir)

    Mix.shell().info("Running task '#{task_name}' on #{length(corpus_files)} documents...")

    Enum.each(corpus_files, fn file ->
      run_document(file, client, template, task_name, run_dir)
    end)

    latest_link = Path.join(out_dir, "#{task_name}_latest")

    case File.read_link(latest_link) do
      {:ok, _} ->
        File.rm!(latest_link)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Warning: #{latest_link}: #{:file.format_error(reason)}")
    end

    File.ln_s!(Path.basename(run_dir), latest_link)

    Mix.shell().info("\nResults written to #{run_dir}/")
    Mix.shell().info("Symlink updated: #{latest_link} -> #{Path.basename(run_dir)}")
  end

  defp run_document(file, client, template, task_name, run_dir) do
    slug = Path.basename(file, ".txt")
    source = File.read!(file)
    Mix.shell().info("  #{slug} (#{byte_size(source)} bytes)...")

    {elapsed_us, {:ok, spans, errors}} =
      :timer.tc(fn ->
        LangExtract.run(client, source, template, max_concurrency: 2)
      end)

    extractions = Enum.map(spans, &span_to_normalized/1)
    elapsed_ms = div(elapsed_us, 1000)

    case errors do
      [] ->
        Mix.shell().info("    #{length(spans)} extractions in #{elapsed_ms}ms")

      _ ->
        Mix.shell().error(
          "    #{length(errors)} chunk error(s), #{length(spans)} partial extractions in #{elapsed_ms}ms"
        )
    end

    error_fields =
      case errors do
        [] -> %{}
        _ -> %{"errors" => Enum.map(errors, &chunk_error_to_map/1)}
      end

    result =
      Map.merge(
        %{
          "source" => slug,
          "task" => task_name,
          "library" => "elixir",
          "extractions" => extractions,
          "timing" => %{"total_ms" => elapsed_ms}
        },
        error_fields
      )

    out_path = Path.join(run_dir, "#{slug}.json")
    File.write!(out_path, Jason.encode!(result, pretty: true))
  end

  defp load_task(name) do
    path = Path.join("benchmark/tasks", "#{name}.json")
    path |> File.read!() |> Jason.decode!()
  end

  defp build_client do
    api_key = System.get_env("ANTHROPIC_API_KEY") || raise "ANTHROPIC_API_KEY not set"

    LangExtract.new(:claude,
      api_key: api_key,
      model: "claude-sonnet-4-20250514",
      temperature: 0,
      req_options: [receive_timeout: 120_000]
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

  defp span_to_normalized(span) do
    %{
      "class" => span.class,
      "text" => span.text,
      "byte_start" => span.byte_start,
      "byte_end" => span.byte_end,
      "status" => Atom.to_string(span.status),
      "attributes" => span.attributes
    }
  end
end
