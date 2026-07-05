defmodule LangExtract.Test.FakeAnthropic do
  @moduledoc """
  A scriptable fake Anthropic endpoint as a `Req.Test` plug, with
  observation probes.

  Because the plug runs inside each chunk's task process, it can observe
  what the pipeline actually does on the wire: how many requests ran
  concurrently (`max_concurrency/1`), how many arrived (`calls/1`), and
  when (`call_times/1`).

  A script is a list of steps consumed by call number; the last step
  repeats. Steps:

    * `{:ok, extractions}` — 200 with the given dynamic-key extractions
    * `{:text, raw}` — 200 whose completion text is `raw` verbatim
      (e.g. malformed JSON the pipeline must survive)
    * `{:status, code, headers}` — bare status response (e.g. 429 + retry-after)
    * `:transport_error` — connection refused
    * `{:delay, ms, step}` — sleep, then respond with `step`

  Probes are plain ETS/atomics owned by the test process — no processes
  to supervise, nothing outlives the test.
  """

  @doc "Installs the scripted stub under `owner` and returns the probe handle."
  def install(owner, script) when is_list(script) do
    probe = %{
      calls: :atomics.new(1, []),
      gauge: :atomics.new(2, []),
      times: :ets.new(:fake_anthropic_times, [:public, :ordered_set])
    }

    Req.Test.stub(owner, fn conn -> serve(conn, script, probe) end)
    probe
  end

  @doc "Total requests received."
  def calls(probe), do: :atomics.get(probe.calls, 1)

  @doc "High-water mark of concurrently open requests."
  def max_concurrency(probe), do: :atomics.get(probe.gauge, 2)

  @doc "Monotonic millisecond timestamps of request arrivals, in order."
  def call_times(probe) do
    probe.times |> :ets.tab2list() |> Enum.map(fn {_order, at} -> at end)
  end

  defp serve(conn, script, probe) do
    n = :atomics.add_get(probe.calls, 1, 1)
    track_arrival(probe, n)

    current = :atomics.add_get(probe.gauge, 1, 1)
    previous_max = :atomics.get(probe.gauge, 2)
    if current > previous_max, do: :atomics.put(probe.gauge, 2, current)

    try do
      respond(conn, Enum.at(script, n - 1, List.last(script)))
    after
      :atomics.sub(probe.gauge, 1, 1)
    end
  end

  defp track_arrival(probe, n) do
    :ets.insert(probe.times, {n, System.monotonic_time(:millisecond)})
  end

  defp respond(conn, {:ok, extractions}) do
    body = %{
      "content" => [
        %{"type" => "text", "text" => Jason.encode!(%{"extractions" => extractions})}
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }

    Req.Test.json(conn, body)
  end

  defp respond(conn, {:text, raw}) do
    body = %{
      "content" => [%{"type" => "text", "text" => raw}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }

    Req.Test.json(conn, body)
  end

  defp respond(conn, {:status, code, headers}) do
    headers
    |> Enum.reduce(conn, fn {key, value}, conn -> Plug.Conn.put_resp_header(conn, key, value) end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(code, "{}")
  end

  defp respond(conn, :transport_error), do: Req.Test.transport_error(conn, :econnrefused)

  defp respond(conn, {:delay, ms, step}) do
    Process.sleep(ms)
    respond(conn, step)
  end
end
