defmodule LangExtract.Runner.Request do
  @moduledoc """
  A single chunk request through the runner's budget, with the runner's
  retry policy.

  Every attempt acquires from the Limiter first and releases after. The
  policy per outcome:

    * `429` — pause the limiter globally until the server's `retry-after`
      deadline and retry. Rate-limit waits never consume the chunk's retry
      budget: the server asked us to wait, not to give up. When
      `retry-after` is absent the pause escalates exponentially from one
      backoff period; either way the Limiter clamps each pause to its 30s
      ceiling, so a hostile deadline delays a run, never hangs it. After
      `:rate_limit_retries` 429s on one chunk (default 10) the chunk fails
      with the rate-limit error — bounded, unlike a budget, only by
      persistence of the 429s.
    * `5xx` / transport error — jittered exponential backoff, consumes one
      unit of `chunk_retries`; budget exhausted returns the last error.
    * any other error (4xx, parse-level) — returned immediately; a bad
      request never gets better by retrying.

  Emits `[:lang_extract, :chunk, :retry]` before each retry with the
  `attempt` number and a compact `reason`
  (`:rate_limited` | `:server_error` | `:transport_error`).

  Internal — no stability guarantees; see the README's "Stability"
  section. Documented because it explains how the library works, not
  because it is API.
  """

  alias LangExtract.{Client, Provider}
  alias LangExtract.Provider.Response
  alias LangExtract.Runner.Limiter

  @max_backoff_ms 10_000
  @default_rate_limit_retries 10

  @spec infer(GenServer.server(), Client.t(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Provider.error()}
  def infer(limiter, %Client{} = client, prompt, opts) do
    attempt(limiter, client, prompt, %{
      budget: Keyword.fetch!(opts, :chunk_retries),
      backoff: Keyword.fetch!(opts, :retry_backoff_ms),
      rate_limit_retries: Keyword.get(opts, :rate_limit_retries, @default_rate_limit_retries),
      attempt: 1,
      spent: 0,
      rate_limited: 0
    })
  end

  defp attempt(limiter, client, prompt, s) do
    Limiter.acquire(limiter)
    result = client.provider.infer(prompt, Client.infer_opts(client))
    Limiter.release(limiter)

    handle(result, limiter, client, prompt, s)
  end

  defp handle({:ok, %Response{}} = ok, _limiter, _client, _prompt, _s), do: ok

  defp handle(
         {:error, {:rate_limited, _}} = error,
         _limiter,
         _client,
         _prompt,
         %{rate_limited: n, rate_limit_retries: cap}
       )
       when n >= cap do
    error
  end

  defp handle({:error, {:rate_limited, retry_after}}, limiter, client, prompt, s) do
    Limiter.pause(limiter, retry_after || rate_limit_pause(s))
    emit_retry(limiter, s.attempt, :rate_limited)

    attempt(limiter, client, prompt, %{
      s
      | attempt: s.attempt + 1,
        rate_limited: s.rate_limited + 1
    })
  end

  defp handle({:error, :server_error} = error, limiter, client, prompt, s) do
    retry_or_give_up(error, :server_error, limiter, client, prompt, s)
  end

  defp handle({:error, {:request_error, _}} = error, limiter, client, prompt, s) do
    retry_or_give_up(error, :transport_error, limiter, client, prompt, s)
  end

  defp handle({:error, _} = error, _limiter, _client, _prompt, _s), do: error

  defp retry_or_give_up(error, _reason, _limiter, _client, _prompt, %{budget: b, spent: b}) do
    error
  end

  defp retry_or_give_up(_error, reason, limiter, client, prompt, s) do
    emit_retry(limiter, s.attempt, reason)
    Process.sleep(backoff_ms(s))
    attempt(limiter, client, prompt, %{s | attempt: s.attempt + 1, spent: s.spent + 1})
  end

  # Absent a server deadline, escalate: a persistently throttled endpoint
  # should slow us down geometrically, not sustain a hot retry loop. The
  # Limiter clamps every pause to its ceiling, so growth here is unbounded.
  defp rate_limit_pause(s) do
    s.backoff * Integer.pow(2, s.rate_limited)
  end

  defp backoff_ms(s) do
    base = min(s.backoff * Integer.pow(2, s.spent), @max_backoff_ms)
    base + :rand.uniform(max(div(s.backoff, 2), 1))
  end

  # The limiter pid identifies which runner retried — operators with
  # several runners can attribute retry storms, and tests can filter
  # events from concurrent suites.
  defp emit_retry(limiter, attempt, reason) do
    :telemetry.execute(
      [:lang_extract, :chunk, :retry],
      %{attempt: attempt},
      %{reason: reason, limiter: limiter}
    )
  end
end
