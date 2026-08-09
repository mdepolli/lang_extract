defmodule LangExtract.Runner.Request do
  @moduledoc """
  A single chunk request through the runner's budget, with the runner's
  retry policy.

  Every attempt acquires from the Limiter first and releases after. The
  policy per outcome:

    * `429` — `release_and_pause` in one cast (so waiters cannot slip in
      between release and pause), then retry. Rate-limit waits never
      consume the chunk's retry budget: the server asked us to wait, not
      to give up. A server-provided `retry-after` is honored verbatim —
      an hour-long quota reset is waited out, not retried against; when
      the header is absent the pause escalates exponentially from one
      backoff period, capped at 30s. A chunk retries up to
      `:rate_limit_retries` times after a 429 (default 10); the next 429
      past that cap fails the chunk with the rate-limit error — bounded,
      unlike a budget, only by persistence of the 429s — while still
      pausing the runner with that final 429's deadline, so giving up
      never hands siblings a hot slot.
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
  @max_rate_limit_pause_ms 30_000
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
    finish(result, limiter, client, prompt, s)
  end

  # Slot is still held when finish/5 runs: 429 must pause before any
  # admission can see a free slot (release_and_pause); everything else
  # releases first so other work can use the budget during backoff.
  defp finish({:ok, %Response{}} = ok, limiter, _client, _prompt, _s) do
    Limiter.release(limiter)
    ok
  end

  # Give-up keeps the pause-before-free invariant: the final 429's
  # retry-after is in hand, and a plain release would hand a hot slot to
  # sibling chunks mid-throttle to burn their own budgets.
  defp finish(
         {:error, {:rate_limited, retry_after}} = error,
         limiter,
         _client,
         _prompt,
         %{rate_limited: n, rate_limit_retries: cap} = s
       )
       when n >= cap do
    Limiter.release_and_pause(limiter, retry_after || rate_limit_pause(s))
    error
  end

  defp finish({:error, {:rate_limited, retry_after}}, limiter, client, prompt, s) do
    Limiter.release_and_pause(limiter, retry_after || rate_limit_pause(s))
    emit_retry(limiter, s.attempt, :rate_limited)

    attempt(limiter, client, prompt, %{
      s
      | attempt: s.attempt + 1,
        rate_limited: s.rate_limited + 1
    })
  end

  defp finish({:error, :server_error} = error, limiter, client, prompt, s) do
    Limiter.release(limiter)
    retry_or_give_up(error, :server_error, limiter, client, prompt, s)
  end

  defp finish({:error, {:request_error, _}} = error, limiter, client, prompt, s) do
    Limiter.release(limiter)
    retry_or_give_up(error, :transport_error, limiter, client, prompt, s)
  end

  defp finish({:error, _} = error, limiter, _client, _prompt, _s) do
    Limiter.release(limiter)
    error
  end

  defp retry_or_give_up(error, _reason, _limiter, _client, _prompt, %{budget: b, spent: b}) do
    error
  end

  defp retry_or_give_up(_error, reason, limiter, client, prompt, s) do
    emit_retry(limiter, s.attempt, reason)
    Process.sleep(backoff_ms(s))
    attempt(limiter, client, prompt, %{s | attempt: s.attempt + 1, spent: s.spent + 1})
  end

  # Absent a server deadline, escalate: a persistently throttled endpoint
  # should slow us down geometrically, not sustain a hot retry loop.
  # Synthesized only — a server-provided retry-after bypasses this and is
  # honored verbatim. Capped here (not in the Limiter, which trusts its
  # callers) so headerless escalation cannot outgrow a pause window:
  # default backoff reaches 200ms * 2^9 = 102s by the last retry.
  defp rate_limit_pause(s) do
    min(s.backoff * Integer.pow(2, s.rate_limited), @max_rate_limit_pause_ms)
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
