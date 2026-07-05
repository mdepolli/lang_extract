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
    * `:retry_backoff_ms` — base backoff for consumed retries (default `200`)
    * `:buffer` — bound on undelivered stream results (default:
      `max_in_flight`); a slow consumer halts admission at this bound
  """

  use Supervisor

  alias LangExtract.{Client, Runner.Limiter}

  @spec start_link(keyword()) :: Supervisor.on_start()
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
      buffer: Keyword.get(opts, :buffer, max_in_flight)
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
    {:ok, http_client} = client.provider.build_http_client(opts)

    %Client{provider: client.provider, options: opts, http_client: http_client}
  end
end
