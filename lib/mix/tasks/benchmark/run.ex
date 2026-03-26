defmodule Mix.Tasks.Benchmark.Run do
  @moduledoc "Run LangExtract benchmark against corpus texts."
  @shortdoc "Run extraction benchmark"

  use Mix.Task

  alias LangExtract.{Extraction, Prompt}

  @default_corpus "benchmark/corpus"
  @default_out "benchmark/results/elixir"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [task: :string, corpus: :string, out: :string, debug_raw_responses: :boolean]
      )

    task_name = opts[:task] || raise "Missing --task argument"
    corpus_dir = opts[:corpus] || @default_corpus
    out_dir = opts[:out] || @default_out
    debug_raw? = opts[:debug_raw_responses] || false

    task_def = load_task(task_name)
    client = build_client()
    template = build_template(task_def)
    corpus_files = Path.wildcard(Path.join(corpus_dir, "*.txt")) |> Enum.sort()

    File.mkdir_p!(out_dir)
    out_path = Path.join(out_dir, "#{task_name}.jsonl")

    debug_dir =
      if debug_raw? do
        dir = Path.join([out_dir, "debug", task_name])
        File.mkdir_p!(dir)
        dir
      end

    Mix.shell().info("Running task '#{task_name}' on #{length(corpus_files)} documents...")

    lines =
      Enum.map(corpus_files, fn file ->
        slug = Path.basename(file, ".txt")
        source = File.read!(file)
        Mix.shell().info("  #{slug} (#{byte_size(source)} bytes)...")

        run_opts = build_run_opts(debug_dir, slug)

        {elapsed_us, result} =
          :timer.tc(fn ->
            LangExtract.run(client, source, template, run_opts)
          end)

        case result do
          {:ok, spans} ->
            extractions = Enum.map(spans, &span_to_normalized/1)
            elapsed_ms = div(elapsed_us, 1000)
            Mix.shell().info("    #{length(spans)} extractions in #{elapsed_ms}ms")

            Jason.encode!(%{
              "source" => slug,
              "task" => task_name,
              "library" => "elixir",
              "extractions" => extractions,
              "timing" => %{"total_ms" => elapsed_ms}
            })

          {:error, reason} ->
            Mix.shell().error("    ERROR: #{inspect(reason)}")

            Jason.encode!(%{
              "source" => slug,
              "task" => task_name,
              "library" => "elixir",
              "extractions" => [],
              "timing" => nil,
              "error" => inspect(reason)
            })
        end
      end)

    File.write!(out_path, Enum.join(lines, "\n") <> "\n")
    Mix.shell().info("\nResults written to #{out_path}")
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

  defp build_run_opts(nil, _slug), do: [max_concurrency: 2]

  defp build_run_opts(debug_dir, slug) do
    counter = :atomics.new(1, [])

    on_chunk_error = fn chunk, raw_output ->
      n = :atomics.add_get(counter, 1, 1)
      path = Path.join(debug_dir, "#{slug}_chunk_#{n}.txt")
      File.write!(path, raw_output)

      Mix.shell().info(
        "    [debug] wrote raw response for chunk at byte #{chunk.byte_start} to #{path}"
      )
    end

    [max_concurrency: 2, on_chunk_error: on_chunk_error]
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
