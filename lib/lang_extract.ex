defmodule LangExtract do
  @moduledoc """
  Extracts structured data from text with source grounding.
  Maps extraction strings back to exact byte positions in source text.

  This module is the main entry point: `new/2` builds a client,
  `template!/2` builds a validated task definition (`template/2` is its
  non-raising twin for runtime task data), `run/4` executes the full
  pipeline, and `align/3` / `extract/3` expose the lower-level steps.
  Beyond the facade:

    * `LangExtract.Prompt.Validator` — pre-flight check that few-shot
      examples align against their own source text
    * `LangExtract.Serializer` — convert results to plain maps and JSONL
      for storage or interop
    * `LangExtract.Extraction` — the extraction struct used in template
      examples and parsed LLM output
  """

  alias LangExtract.{
    Client,
    Extraction,
    Orchestrator,
    Pipeline,
    Provider,
    Result,
    Span,
    Template
  }

  alias LangExtract.Alignment.Aligner
  alias LangExtract.Prompt.Validator
  alias LangExtract.Prompt.Validator.ValidationError

  @doc """
  Aligns extraction strings to byte spans in source text.

  Returns a list of `%LangExtract.Span{}` structs, one per extraction.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      iex> LangExtract.align("the quick brown fox", ["quick brown"])
      [%LangExtract.Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact}]

  """
  @spec align(String.t(), [String.t()], keyword()) :: [LangExtract.Span.t()]
  def align(source, extractions, opts \\ []) do
    Aligner.align(source, extractions, opts)
  end

  @doc """
  Parses LLM output, aligns extractions against source text, and returns
  enriched spans with class and attributes.

  Accepts both canonical and dynamic-key format (where each entry uses
  the class name as the key). JSON only (since 0.7.0). Strips markdown fences
  and think tags before parsing.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      iex> raw = ~s({"extractions": [{"class": "word", "text": "fox"}]})
      iex> {:ok, [span]} = LangExtract.extract("the quick brown fox", raw)
      iex> span.status
      :exact

  """
  @spec extract(String.t(), String.t(), keyword()) ::
          {:ok, [Span.t()]}
          | {:error, {:invalid_format, String.t()} | :missing_extractions}
  defdelegate extract(source, raw_llm_output, opts \\ []), to: Pipeline

  @doc """
  Runs the full extraction pipeline: prompt → LLM → parse → align.

  Returns `{:ok, %Result{}}` on success — document-ordered spans plus
  per-chunk errors. When some chunks fail to parse, the successful spans
  are still returned alongside the errors. Returns `{:error, reason}` only
  for infrastructure failures (task exits, timeouts).

  Not a drop-in swap with `LangExtract.Runner.run/4` despite the matching
  shape: the runner retries failures into per-chunk errors and never
  returns `{:error, _}`, while this function abandons the document on a
  task exit. See the failure-semantics table in the "Running in
  Production" guide.

  ## Options

    * `:max_chunk_chars` - chunk size in characters (default `1000`)
    * `:max_concurrency` - parallel chunk requests (default `10`)
    * `:task_timeout` - per-chunk task timeout (default `:infinity`)
    * `:fuzzy_threshold` - minimum LCS coverage for fuzzy match (default `0.75`)
    * `:min_density` - minimum matched-token density of a fuzzy span (default `1/3`)
    * `:accept_lesser` - allow prefix-fragment grounding (default `true`)
    * `:exact_algorithm` - `:dp` (occurrence DP, default) or `:first_occurrence`

  Chunk size is measured in characters; span offsets are always bytes.
  See the "Alignment and Spans" guide for what the alignment options tune.

  ## Examples

      client = LangExtract.new(:claude, api_key: "sk-...")
      template = LangExtract.template!("Extract entities.")

      {:ok, %LangExtract.Result{spans: spans, errors: errors}} =
        LangExtract.run(client, "the quick brown fox", template)

  """
  @spec run(Client.t(), String.t(), Template.t(), keyword()) ::
          {:ok, Result.t()} | {:error, {:task_exit, term()}}
  def run(%Client{} = client, source, %Template{} = template, opts \\ []) do
    Orchestrator.run(client, source, template, opts)
  end

  @doc """
  Streams per-chunk extraction results as each chunk completes.

  Returns a lazy stream of `{:ok, %ChunkResult{}}` and
  `{:error, %ChunkError{}}` events in **completion order**, not
  document order — consumers who need latency don't wait for slow chunks;
  consumers who need order sort by the byte ranges every event carries.
  Nothing runs until the stream is consumed, and a slow consumer naturally
  limits how many chunk requests are in flight.

  Failure semantics differ from `run/4` deliberately: every failure stays
  per-chunk. A chunk whose task times out is reported as
  `{:error, %ChunkError{reason: {:task_exit, :timeout}}}` with its byte
  range, and the remaining chunks keep flowing — where `run/4` abandons
  the document and returns `{:error, {:task_exit, reason}}`.

  Takes the same options as `run/4`.

  ## Examples

      client
      |> LangExtract.stream(document, template)
      |> Enum.each(fn
        {:ok, chunk_result} -> handle_spans(chunk_result.spans)
        {:error, chunk_error} -> log_failure(chunk_error)
      end)

  """
  @spec stream(Client.t(), String.t(), Template.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, source, %Template{} = template, opts \\ []) do
    Orchestrator.stream(client, source, template, opts)
  end

  @doc """
  Builds a validated extraction template.

  Examples are given as plain maps (string or atom keys, so JSON-loaded
  task definitions work verbatim) or as ready-made structs. Map-authored
  attributes are normalized to string keys, matching the wire format's
  decoded shape; ready-made structs pass through unchanged. Each example's
  extraction texts are validated against the example text using the
  production aligner; misaligned examples raise
  `LangExtract.Prompt.Validator.ValidationError` — a template that
  constructs is a template whose examples align. Pass `validate: false`
  to skip. For runtime data where raising is inappropriate, `template/2`
  returns tagged tuples instead.

  ## Examples

      iex> template =
      ...>   LangExtract.template!("Extract conditions.",
      ...>     examples: [
      ...>       %{text: "Patient has diabetes.",
      ...>         extractions: [%{class: "condition", text: "diabetes"}]}
      ...>     ]
      ...>   )
      iex> [example] = template.examples
      iex> example.extractions
      [%LangExtract.Extraction{class: "condition", text: "diabetes", attributes: %{}}]

  """
  @spec template!(String.t(), keyword()) :: Template.t()
  def template!(description, opts \\ []) when is_binary(description) do
    case template(description, opts) do
      {:ok, template} -> template
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Builds a validated extraction template, returning a tagged tuple.

  The non-raising twin of `template!/2` for templates built from runtime
  data (user-uploaded or JSON-loaded task definitions). Returns
  `{:error, exception}` where `template!/2` would raise — an
  `ArgumentError` for malformed example maps, or a
  `LangExtract.Prompt.Validator.ValidationError` (carrying the per-example
  issues) for examples whose extractions don't align.

  ## Examples

      iex> {:error, %ArgumentError{}} =
      ...>   LangExtract.template("Extract.", examples: [%{extractions: []}])

  """
  @spec template(String.t(), keyword()) ::
          {:ok, Template.t()} | {:error, Exception.t()}
  def template(description, opts \\ []) when is_binary(description) do
    examples = Keyword.get(opts, :examples, [])
    validate = Keyword.get(opts, :validate, true)

    case normalize_all(examples, &normalize_example/1) do
      {:ok, examples} ->
        validate_template(%Template{description: description, examples: examples}, validate)

      {:error, _} = error ->
        error
    end
  end

  defp normalize_all(items, fun) do
    items
    |> Enum.reduce_while([], fn item, acc ->
      case fun.(item) do
        {:ok, value} -> {:cont, [value | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp normalize_example(%Template.Example{} = example), do: {:ok, example}

  defp normalize_example(%{} = map) do
    with {:ok, text} <- fetch_string(map, :text, "example"),
         {:ok, list} <- expect_list(get_field(map, :extractions, []), :extractions, "example"),
         {:ok, extractions} <- normalize_all(list, &normalize_extraction/1) do
      {:ok, %Template.Example{text: text, extractions: extractions}}
    end
  end

  defp normalize_example(other) do
    {:error, ArgumentError.exception("example must be a map, got: #{inspect(other)}")}
  end

  defp normalize_extraction(%Extraction{} = extraction), do: {:ok, extraction}

  defp normalize_extraction(%{} = map) do
    with {:ok, class} <- fetch_string(map, :class, "extraction"),
         {:ok, text} <- fetch_string(map, :text, "extraction"),
         {:ok, attributes} <-
           expect_map(get_field(map, :attributes, %{}), :attributes, "extraction") do
      {:ok,
       %Extraction{class: class, text: text, attributes: normalize_attribute_keys(attributes)}}
    end
  end

  defp normalize_extraction(other) do
    {:error, ArgumentError.exception("extraction must be a map, got: #{inspect(other)}")}
  end

  # The wire format decodes attributes with string keys (JSON); template
  # examples must produce the same shape regardless of how they were
  # authored, so prompt-rendered examples and parsed output never differ
  # by key type. Values pass through verbatim.
  defp normalize_attribute_keys(attributes) do
    Map.new(attributes, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp fetch_string(map, key, owner) do
    case get_field(map, key, nil) do
      nil ->
        {:error,
         ArgumentError.exception(
           "#{owner} is missing required key #{inspect(key)}: #{inspect(map)}"
         )}

      value when is_binary(value) ->
        {:ok, value}

      value ->
        type_error(owner, key, "a string", value)
    end
  end

  defp expect_list(value, _key, _owner) when is_list(value), do: {:ok, value}
  defp expect_list(value, key, owner), do: type_error(owner, key, "a list", value)

  defp expect_map(value, _key, _owner) when is_map(value), do: {:ok, value}
  defp expect_map(value, key, owner), do: type_error(owner, key, "a map", value)

  defp type_error(owner, key, expected, value) do
    {:error,
     ArgumentError.exception(
       "#{owner} key #{inspect(key)} must be #{expected}, got: #{inspect(value)}"
     )}
  end

  defp get_field(map, key, default) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp validate_template(template, false), do: {:ok, template}

  defp validate_template(template, true) do
    case Validator.validate(template) do
      :ok -> {:ok, template}
      {:error, issues} -> {:error, ValidationError.exception(issues: issues)}
    end
  end

  @type provider :: :claude | :openai | :gemini

  @doc """
  Creates a configured LLM client for extraction.

  Raises `ArgumentError` on an unknown provider or unbuildable HTTP client
  (e.g. missing API key). The raise is deliberate: misconfiguration here is
  a programmer error caught at client construction, while runtime failures
  during extraction (`run/4`, `extract/3`) return tagged tuples.

  ## Examples

      client = LangExtract.new(:claude, api_key: "sk-...")
      client = LangExtract.new(:openai, api_key: "sk-...", model: "gpt-4o")
      client = LangExtract.new(:gemini, api_key: "gm-...")

  """
  @spec new(provider(), keyword()) :: Client.t()
  def new(provider, opts \\ []) do
    module = resolve_provider(provider)

    case module.build_http_client(opts) do
      {:ok, req} -> %Client{provider: module, options: opts, http_client: req}
      {:error, reason} -> raise ArgumentError, "failed to build HTTP client: #{inspect(reason)}"
    end
  end

  defp resolve_provider(:claude), do: Provider.Claude
  defp resolve_provider(:openai), do: Provider.OpenAI
  defp resolve_provider(:gemini), do: Provider.Gemini

  defp resolve_provider(other) do
    raise ArgumentError,
          "unknown provider: #{inspect(other)}. Expected :claude, :openai, or :gemini"
  end
end
