defmodule LangExtract do
  @moduledoc """
  Extracts structured data from text with source grounding.
  Maps extraction strings back to exact byte positions in source text.

  This module is the main entry point: `new/2` builds a client,
  `template/2` builds a validated task definition, and `run/4` /
  `stream/4` execute the full pipeline (chunk → LLM → parse → align).
  For replaying stored model output without another API call, see
  `extract/3`.

  Beyond the facade:

    * `LangExtract.Prompt.Validator` — pre-flight check that few-shot
      examples align against their own source text
    * `LangExtract.Serializer` — convert results to plain maps and JSONL
      for storage or interop
    * `LangExtract.Extraction` — the extraction struct used in template
      examples and parsed LLM output
    * `LangExtract.Alignment.Aligner` — the grounding engine the pipeline
      already runs for you (public but best-effort; see Stability in the
      README)
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
  Lower-level: aligns bare extraction strings to byte spans in source text.

  Prefer `run/4` / `stream/4` for documents (they chunk, then ground) and
  `extract/3` when you already have model JSON. This is a thin wrapper over
  `LangExtract.Alignment.Aligner` for tests, tooling, and callers who need
  the engine directly — the same engine the pipeline uses on each chunk.
  It aligns against the source as given: the fuzzy fallthrough phases scale
  super-linearly in source tokens, so a book-length source can cost seconds
  per unmatched extraction where the pipeline's ~200-token chunks stay fast.

  Returns a list of `%LangExtract.Span{}` structs, one per extraction
  (`class` is always `nil` and `attributes` always empty).

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)
    * `:min_density` - minimum matched-token density for fuzzy (default `1/3`)
    * `:accept_lesser` - accept prefix partial matches (default `true`)
    * `:exact_algorithm` - `:dp` (default) or `:first_occurrence`

  ## Examples

      iex> LangExtract.align("the quick brown fox", ["quick brown"])
      [%LangExtract.Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact}]

  """
  @spec align(String.t(), [String.t()], keyword()) :: [LangExtract.Span.t()]
  def align(source, extractions, opts \\ []) do
    Aligner.align(source, extractions, opts)
  end

  @doc """
  Parses raw LLM output, aligns extractions against source text, and returns
  spans with class and attributes.

  Use this to replay or re-ground a stored model response without calling the
  provider again. For live extraction from a document, use `run/4`.

  Accepts both canonical and dynamic-key format (where each entry uses
  the class name as the key). JSON only (since 0.7.0). Strips markdown fences
  and think tags before parsing.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)
    * `:min_density` - minimum matched-token density for fuzzy (default `1/3`)
    * `:accept_lesser` - accept prefix partial matches (default `true`)
    * `:exact_algorithm` - `:dp` (default) or `:first_occurrence`

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

  Returns a `%Result{}` — document-ordered spans plus per-chunk errors.
  This function cannot fail; `Result.errors` is the failure channel.
  Every failure stays per-chunk: a chunk that fails to parse or times
  out lands in `errors` as a `%ChunkError{}` with its byte range, and
  the surviving chunks' spans are still returned. Chunk tasks run
  linked, so a bug-level crash inside one propagates to the caller.

  `LangExtract.Runner.run/4` shares this return contract, adding
  retries, a shared request budget, and crash isolation (its supervised
  tasks report crashes as `ChunkError`s too) on top. See the
  failure-semantics table in the "Running in Production" guide.

  ## Options

    * `:max_chunk_chars` - chunk size in characters (default `1000`)
    * `:max_concurrency` - parallel chunk requests (default `10`)
    * `:task_timeout` - per-chunk task timeout (default `:infinity`).
      Standalone `run/4`/`stream/4` only — `LangExtract.Runner` ignores
      it; its requests are bounded by HTTP timeouts and the retry policy
    * `:fuzzy_threshold` - minimum LCS coverage for fuzzy match (default `0.75`)
    * `:min_density` - minimum matched-token density of a fuzzy span (default `1/3`)
    * `:accept_lesser` - allow prefix-fragment grounding as `:lesser` spans (default `true`)
    * `:exact_algorithm` - `:dp` (occurrence DP, default) or `:first_occurrence`

  The chunk budget is measured in characters because it mirrors upstream
  langextract's `max_char_buffer`: counting the same way keeps chunk
  boundaries identical across the two libraries, which the cross-library
  benchmarks depend on. Every output offset is bytes, and since chunking
  is sentence-aware, boundaries can't be computed from the budget in
  either unit — the byte ranges on results are the boundary source of
  truth. See the "Alignment and Spans" guide for what the alignment
  options tune.

  ## Examples

      client = LangExtract.new(:claude, api_key: "sk-...")
      template = LangExtract.template("Extract entities.")

      %LangExtract.Result{spans: spans, errors: errors} =
        LangExtract.run(client, "the quick brown fox", template)

  """
  @spec run(Client.t(), String.t(), Template.t(), keyword()) :: Result.t()
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

  Failure semantics match `run/4`: every failure stays per-chunk. A chunk
  whose task times out is reported as
  `{:error, %ChunkError{reason: {:task_exit, :timeout}}}` with its byte
  range, and the remaining chunks keep flowing — `run/4` is exactly this
  stream, collected and restored to document order.

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
  constructs is a template whose examples align, unconditionally.
  Malformed example maps raise `ArgumentError` naming the offending field.

  Raising without a bang follows the convention for single-variant
  functions (`new/2` is the same shape): a malformed template is a
  programmer error, caught closest to the typo.

  ## Examples

      iex> template =
      ...>   LangExtract.template("Extract conditions.",
      ...>     examples: [
      ...>       %{text: "Patient has diabetes.",
      ...>         extractions: [%{class: "condition", text: "diabetes"}]}
      ...>     ]
      ...>   )
      iex> [example] = template.examples
      iex> example.extractions
      [%LangExtract.Extraction{class: "condition", text: "diabetes", attributes: %{}}]

  """
  @spec template(String.t(), keyword()) :: Template.t()
  def template(description, opts \\ []) when is_binary(description) do
    examples = Keyword.get(opts, :examples, [])

    with {:ok, examples} <- expect_list(examples, :examples, "template"),
         {:ok, examples} <- normalize_all(examples, &normalize_example/1),
         {:ok, template} <-
           validate_template(%Template{description: description, examples: examples}) do
      template
    else
      {:error, exception} -> raise exception
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

  # The classic examples/extractions mix-up: an extraction (or
  # %Extraction{}) passed at example level has :text, and :extractions
  # defaults to [] — it would build a validated template whose few-shot
  # example teaches the model to extract nothing. A legitimate example
  # never carries :class.
  defp normalize_example(%{} = map) when is_map_key(map, :class) or is_map_key(map, "class") do
    {:error,
     ArgumentError.exception(
       "extraction-shaped map given as an example (carries a class key) — wrap it in " <>
         "an example: %{text: source_text, extractions: [extraction]}"
     )}
  end

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

  # WireFormat reserves "class" and "text" as canonical marker keys on the
  # wire. Encoding class "text" as a dynamic key produces {"text": "..."},
  # which the decoder treats as a marker — every conforming model reply is
  # then skipped with only a warning log. The "_attributes" suffix is
  # reserved the same way: class "note_attributes" encodes to a key the
  # decoder reads as attributes for class "note".
  @reserved_classes ~w(class text)
  @reserved_suffix "_attributes"

  defp normalize_extraction(%Extraction{class: class} = extraction) do
    case reject_reserved_class(class) do
      :ok -> {:ok, extraction}
      {:error, _} = error -> error
    end
  end

  defp normalize_extraction(%{} = map) do
    with {:ok, class} <- fetch_string(map, :class, "extraction"),
         :ok <- reject_reserved_class(class),
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

  defp reject_reserved_class(class) when class in @reserved_classes do
    {:error,
     ArgumentError.exception(
       "extraction class #{inspect(class)} is a reserved class name " <>
         "(WireFormat marker keys); choose another class"
     )}
  end

  defp reject_reserved_class(class) do
    if String.ends_with?(class, @reserved_suffix) do
      {:error,
       ArgumentError.exception(
         "extraction class #{inspect(class)} ends with the reserved suffix " <>
           "#{inspect(@reserved_suffix)} (WireFormat attribute-carrier keys); " <>
           "choose another class"
       )}
    else
      :ok
    end
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
    case fetch_field(map, key) do
      :error ->
        {:error,
         ArgumentError.exception(
           "#{owner} is missing required key #{inspect(key)}: #{inspect(map)}"
         )}

      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, value} ->
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

  # Present vs absent — never ||. Explicit nil/false must reach type
  # checks (teach-nothing silent defaults) rather than collapsing to the
  # field default the way Map.get + || does.
  defp get_field(map, key, default) do
    case fetch_field(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, _} = ok -> ok
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch_field(map, key), do: Map.fetch(map, key)

  defp validate_template(template) do
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
  during extraction stay data — per-chunk errors in `run/4`'s `Result`,
  tagged tuples from `extract/3`.

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
