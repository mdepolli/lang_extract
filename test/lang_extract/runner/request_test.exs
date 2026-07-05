defmodule LangExtract.Runner.RequestTest do
  use ExUnit.Case, async: true

  alias LangExtract.Runner.{Limiter, Request}

  @opts [chunk_retries: 3, retry_backoff_ms: 1]

  # Module-qualified capture, not an anonymous fn, so telemetry stores it
  # without the local-handler penalty; the parent pid travels as config.
  def forward_event(event, measurements, metadata, parent) do
    send(parent, {event, measurements, metadata})
  end

  setup do
    handler_id = "request-retry-telemetry-#{inspect(self())}"

    :telemetry.attach(
      handler_id,
      [:lang_extract, :chunk, :retry],
      &__MODULE__.forward_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    limiter = start_supervised!({Limiter, [max_in_flight: 5]})
    calls = start_supervised!({Agent, fn -> 0 end})

    %{limiter: limiter, calls: calls}
  end

  defp client do
    LangExtract.new(:claude,
      api_key: "sk-test",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )
  end

  defp ok_body do
    %{
      "content" => [%{"type" => "text", "text" => "hello"}],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  # Responds from `script` by call number; repeats the last entry.
  defp scripted_stub(calls, script) do
    Req.Test.stub(__MODULE__, fn conn ->
      n = Agent.get_and_update(calls, fn n -> {n + 1, n + 1} end)
      respond(conn, Enum.at(script, n - 1, List.last(script)))
    end)
  end

  defp respond(conn, :ok), do: Req.Test.json(conn, ok_body())

  defp respond(conn, {:status, code, headers}) do
    headers
    |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(code, "{}")
  end

  defp respond(conn, :transport_error), do: Req.Test.transport_error(conn, :econnrefused)

  test "success passes straight through", %{limiter: limiter, calls: calls} do
    scripted_stub(calls, [:ok])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert Agent.get(calls, & &1) == 1
    refute_receive {[:lang_extract, :chunk, :retry], _, %{limiter: ^limiter}}
  end

  test "429 pauses the limiter globally and retries without spending budget",
       %{limiter: limiter, calls: calls} do
    scripted_stub(calls, [{:status, 429, [{"retry-after", "0"}]}, :ok])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert Agent.get(calls, & &1) == 2

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 1},
                    %{reason: :rate_limited, limiter: ^limiter}}
  end

  test "429 without retry-after uses one backoff period as the pause",
       %{limiter: limiter, calls: calls} do
    scripted_stub(calls, [{:status, 429, []}, :ok])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert Agent.get(calls, & &1) == 2
  end

  test "5xx retries with budget and succeeds within it", %{limiter: limiter, calls: calls} do
    scripted_stub(calls, [{:status, 500, []}, {:status, 503, []}, :ok])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert Agent.get(calls, & &1) == 3

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 1},
                    %{reason: :server_error, limiter: ^limiter}}

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 2},
                    %{reason: :server_error, limiter: ^limiter}}
  end

  test "budget exhaustion returns the last error", %{limiter: limiter, calls: calls} do
    scripted_stub(calls, [{:status, 500, []}])

    assert {:error, :server_error} =
             Request.infer(limiter, client(), "prompt", chunk_retries: 2, retry_backoff_ms: 1)

    # initial attempt + 2 budgeted retries
    assert Agent.get(calls, & &1) == 3
  end

  test "transport errors consume budget with :transport_error reason",
       %{limiter: limiter, calls: calls} do
    scripted_stub(calls, [:transport_error, :ok])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 1},
                    %{reason: :transport_error, limiter: ^limiter}}
  end

  test "4xx returns immediately without retrying", %{limiter: limiter, calls: calls} do
    scripted_stub(calls, [{:status, 400, []}, :ok])

    assert {:error, {:bad_request, _}} = Request.infer(limiter, client(), "prompt", @opts)
    assert Agent.get(calls, & &1) == 1
    refute_receive {[:lang_extract, :chunk, :retry], _, %{limiter: ^limiter}}
  end

  test "in-flight slot is released between attempts", %{limiter: limiter, calls: calls} do
    # max_in_flight is 5; a request retrying 3 times would deadlock itself
    # if it held its slot across attempts on a max_in_flight: 1 limiter.
    tight_limiter = start_supervised!({Limiter, [max_in_flight: 1]}, id: :tight)
    scripted_stub(calls, [{:status, 500, []}, {:status, 500, []}, :ok])

    assert {:ok, "hello"} = Request.infer(tight_limiter, client(), "prompt", @opts)
  end
end
