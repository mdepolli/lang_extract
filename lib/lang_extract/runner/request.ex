defmodule LangExtract.Runner.Request do
  @moduledoc """
  A single chunk request through the runner's budget, with the runner's
  retry policy.

  Every attempt acquires from the Limiter first and releases after. The
  policy per outcome:

    * `429` — pause the limiter globally until the server's `retry-after`
      deadline (or one backoff period when absent) and retry. Rate-limit
      waits never consume the chunk's retry budget: the server asked us to
      wait, not to give up.
    * `5xx` / transport error — jittered exponential backoff, consumes one
      unit of `chunk_retries`; budget exhausted returns the last error.
    * any other error (4xx, parse-level) — returned immediately; a bad
      request never gets better by retrying.

  Emits `[:lang_extract, :chunk, :retry]` before each retry with the
  `attempt` number and a compact `reason`
  (`:rate_limited` | `:server_error` | `:transport_error`).
  """

  alias LangExtract.Client
  alias LangExtract.Runner.Limiter

  @max_backoff_ms 10_000

  @spec infer(GenServer.server(), Client.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def infer(limiter, %Client{} = client, prompt, opts) do
    attempt(limiter, client, prompt, %{
      budget: Keyword.fetch!(opts, :chunk_retries),
      backoff: Keyword.fetch!(opts, :retry_backoff_ms),
      attempt: 1,
      spent: 0
    })
  end

  defp attempt(limiter, client, prompt, s) do
    Limiter.acquire(limiter)
    result = client.provider.infer(prompt, Client.infer_opts(client))
    Limiter.release(limiter)

    handle(result, limiter, client, prompt, s)
  end

  defp handle({:ok, text}, _limiter, _client, _prompt, _s), do: {:ok, text}

  defp handle({:error, {:rate_limited, retry_after}}, limiter, client, prompt, s) do
    Limiter.pause(limiter, retry_after || s.backoff)
    emit_retry(s.attempt, :rate_limited)
    attempt(limiter, client, prompt, %{s | attempt: s.attempt + 1})
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
    emit_retry(s.attempt, reason)
    Process.sleep(backoff_ms(s))
    attempt(limiter, client, prompt, %{s | attempt: s.attempt + 1, spent: s.spent + 1})
  end

  defp backoff_ms(s) do
    base = min(s.backoff * Integer.pow(2, s.spent), @max_backoff_ms)
    base + :rand.uniform(max(div(s.backoff, 2), 1))
  end

  defp emit_retry(attempt, reason) do
    :telemetry.execute([:lang_extract, :chunk, :retry], %{attempt: attempt}, %{reason: reason})
  end
end
