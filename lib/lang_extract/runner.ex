defmodule LangExtract.Runner do
  @moduledoc """
  A caller-owned, supervised extraction runner with a shared request budget.

  Place it in your supervision tree — no global names, no app env, no
  library-side singleton; multiple independent runners coexist:

      # application.ex
      {LangExtract.Runner,
       name: MyApp.Extractor,
       client: LangExtract.new(:claude, api_key: key),
       max_in_flight: 20,
       rpm: 2_000,
       chunk_retries: 3}

  All extraction scheduled through the runner shares one budget: concurrent
  callers cannot jointly exceed `:rpm` or `:max_in_flight`, and a single
  429 pauses every in-flight chunk until the server's `retry-after`
  deadline (see `LangExtract.Runner.Limiter`).

  Requests made through the runner disable Req's transient retry — the
  runner owns the retry policy (see `LangExtract.Runner.Request`).
  Standalone `LangExtract.run/4` and `stream/4` keep Req's retry exactly
  as before.

  ## Options

    * `:client` (required) — the `LangExtract.Client` to extract with
    * `:name` — registered name for the runner
    * `:max_in_flight` — concurrent request cap (default `10`)
    * `:rpm` — requests-per-minute budget (default `:infinity`)
    * `:chunk_retries` — retry budget per chunk for 5xx/transport failures
      (default `3`); 429 waits never consume it
    * `:rate_limit_retries` — cap on 429 retries per chunk (default `10`);
      past it the chunk fails with the rate-limit error
    * `:retry_backoff_ms` — base backoff for consumed retries (default `200`)
    * `:buffer` — bound on undelivered stream results (default:
      `max_in_flight`); a slow consumer halts admission at this bound
    * `:drain_timeout` — grace period in ms for in-flight requests to
      finish when the runner shuts down (default `5_000`); chunks never
      started are reported as `%ChunkError{reason: :drained}`
  """

  use Supervisor

  alias LangExtract.{Client, Orchestrator, Result, Template}
  alias LangExtract.Runner.{Delivery, Limiter, Request}

  @type option ::
          {:client, Client.t()}
          | {:name, GenServer.name()}
          | {:max_in_flight, pos_integer()}
          | {:rpm, pos_integer() | :infinity}
          | {:chunk_retries, non_neg_integer()}
          | {:rate_limit_retries, non_neg_integer()}
          | {:retry_backoff_ms, pos_integer()}
          | {:buffer, pos_integer()}
          | {:drain_timeout, non_neg_integer()}

  @doc """
  Starts the runner supervisor. See the module docs for options.
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    sup_opts = if name, do: [name: name], else: []
    Supervisor.start_link(__MODULE__, opts, sup_opts)
  end

  @impl true
  def init(opts) do
    client = Keyword.fetch!(opts, :client)
    max_in_flight = Keyword.get(opts, :max_in_flight, 10)

    config = %{
      client: disable_req_retry(client),
      chunk_retries: Keyword.get(opts, :chunk_retries, 3),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 200),
      rate_limit_retries: Keyword.get(opts, :rate_limit_retries, 10),
      buffer: Keyword.get(opts, :buffer, max_in_flight),
      drain_timeout: Keyword.get(opts, :drain_timeout, 5_000)
    }

    children = [
      %{id: :config, start: {Agent, :start_link, [fn -> config end]}},
      %{
        id: :limiter,
        start:
          {Limiter, :start_link,
           [[rpm: Keyword.get(opts, :rpm, :infinity), max_in_flight: max_in_flight]]}
      },
      %{id: :task_supervisor, start: {Task.Supervisor, :start_link, [[]]}}
    ]

    # one_for_all: a crashed Limiter loses the in-flight ledger, and a
    # crashed Task.Supervisor orphans budget holders — partial restarts
    # would leak slots, so the whole cell restarts together.
    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Streams per-chunk results through the runner's shared budget.

  Same event shape as `LangExtract.stream/4` — `{:ok, %ChunkResult{}}` and
  `{:error, %ChunkError{}}` in completion order — but chunk requests are
  scheduled through the runner's Limiter (rpm + in-flight budget, global
  429 backoff) and retried per the runner's policy. Task-level failures
  stay per-chunk. Delivery is bounded: at most `:buffer` results are
  outstanding, so a slow consumer throttles admission.

  Accepts `run/4`'s chunking and alignment options plus `:buffer`
  (default: the runner's configured buffer).
  """
  @spec stream(Supervisor.supervisor(), String.t(), Template.t(), keyword()) :: Enumerable.t()
  def stream(runner, source, %Template{} = template, opts \\ []) do
    %{config: config, limiter: limiter, task_supervisor: task_sup} = resources(runner)

    chunks = Orchestrator.chunk_source(source, opts)
    buffer = Keyword.get(opts, :buffer, config.buffer)

    retry_opts = [
      chunk_retries: config.chunk_retries,
      retry_backoff_ms: config.retry_backoff_ms,
      rate_limit_retries: config.rate_limit_retries
    ]

    process = fn chunk ->
      Orchestrator.process_chunk(chunk, template, opts, fn prompt ->
        Request.infer(limiter, config.client, prompt, retry_opts)
      end)
    end

    task_sup
    |> Delivery.stream_events(chunks, process, buffer: buffer, shutdown: config.drain_timeout)
    |> Orchestrator.with_document_events(length(chunks), %{source_bytes: byte_size(source)})
  end

  @doc """
  Runs a full extraction through the runner's shared budget.

  Collects `stream/4` and restores document order. Returns a
  `%LangExtract.Result{}` — the same contract as `LangExtract.run/4`,
  with retries and the shared request budget on top. Every failure is
  per-chunk: a crashed chunk task lands in the result's `errors` with
  reason `{:task_exit, reason}`, so this function cannot fail and
  `Result.errors` is the failure channel.

  The runner has no per-chunk deadline: `:task_timeout` belongs to the
  standalone path and is ignored here. Each attempt is bounded by the
  client's HTTP timeouts and the retry policy instead, and a shutdown
  converts still-running chunks to errors within `drain_timeout`.
  """
  @spec run(Supervisor.supervisor(), String.t(), Template.t(), keyword()) :: Result.t()
  def run(runner, source, %Template{} = template, opts \\ []) do
    runner
    |> stream(source, template, opts)
    |> Orchestrator.collect()
  end

  @doc """
  Streams a whole corpus through the runner's shared budget.

  Takes an enumerable of `{id, source}` pairs and yields `{id, event}` in
  the same event shape as `stream/4`. Documents are processed in order,
  each with its own document telemetry span; chunk-level concurrency
  within a document follows the runner's budget and buffer. Lazy — a
  document's extraction starts only when the stream reaches it.
  """
  @spec stream_corpus(Supervisor.supervisor(), Enumerable.t(), Template.t(), keyword()) ::
          Enumerable.t()
  def stream_corpus(runner, docs, %Template{} = template, opts \\ []) do
    # Runner resources are deliberately re-resolved per document (inside
    # stream/4), not hoisted: the limiter/task-supervisor pids go stale if
    # the one_for_all cell restarts mid-corpus, and per-document resolution
    # lets the corpus continue on the fresh children instead of draining
    # every remaining document. Two messages per multi-second document.
    Stream.flat_map(docs, fn {id, source} ->
      runner
      |> stream(source, template, opts)
      |> Stream.map(&{id, &1})
    end)
  end

  @doc false
  @spec resources(Supervisor.supervisor()) :: %{
          config: map(),
          limiter: pid(),
          task_supervisor: pid()
        }
  def resources(runner) do
    children =
      Map.new(Supervisor.which_children(runner), fn {id, pid, _type, _mods} -> {id, pid} end)

    %{
      config: Agent.get(children.config, & &1),
      limiter: children.limiter,
      task_supervisor: children.task_supervisor
    }
  end

  # The runner owns retries, so Req's transient retry is disabled for
  # requests scheduled through it. Double retry layers multiply attempts
  # and hide the real failure. The caller's other req_options (plugs,
  # timeouts) are preserved; the http_client is rebuilt with the merged
  # options.
  defp disable_req_retry(%Client{} = client) do
    req_options =
      client.options
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(retry: false)

    opts = Keyword.put(client.options, :req_options, req_options)

    case client.provider.build_http_client(opts) do
      {:ok, http_client} ->
        %Client{provider: client.provider, options: opts, http_client: http_client}

      {:error, reason} ->
        raise ArgumentError,
              "runner failed to rebuild the client's HTTP client: #{inspect(reason)}. " <>
                "The client built successfully at LangExtract.new/2 — if its API key " <>
                "came from an env var, has it been unset since?"
    end
  end
end
