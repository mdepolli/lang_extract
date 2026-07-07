defmodule LangExtract.Runner.RequestTest do
  use ExUnit.Case, async: true

  alias LangExtract.Runner.{Limiter, Request}
  alias LangExtract.Test.FakeAnthropic

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

    %{limiter: start_supervised!({Limiter, [max_in_flight: 5]})}
  end

  defp client do
    LangExtract.new(:claude,
      api_key: "sk-test",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )
  end

  test "success passes straight through", %{limiter: limiter} do
    probe = FakeAnthropic.install(__MODULE__, [{:text, "hello"}])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert FakeAnthropic.calls(probe) == 1
    refute_receive {[:lang_extract, :chunk, :retry], _, %{limiter: ^limiter}}
  end

  test "429 pauses the limiter globally and retries without spending budget",
       %{limiter: limiter} do
    probe =
      FakeAnthropic.install(__MODULE__, [{:status, 429, [{"retry-after", "0"}]}, {:text, "hello"}])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert FakeAnthropic.calls(probe) == 2

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 1},
                    %{reason: :rate_limited, limiter: ^limiter}}
  end

  test "429 without retry-after uses one backoff period as the pause",
       %{limiter: limiter} do
    probe = FakeAnthropic.install(__MODULE__, [{:status, 429, []}, {:text, "hello"}])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert FakeAnthropic.calls(probe) == 2
  end

  test "persistent 429s hit the rate-limit cap with escalating pauses",
       %{limiter: limiter} do
    probe = FakeAnthropic.install(__MODULE__, [{:status, 429, []}])
    started = System.monotonic_time(:millisecond)

    assert {:error, {:rate_limited, nil}} =
             Request.infer(limiter, client(), "prompt",
               chunk_retries: 3,
               retry_backoff_ms: 20,
               rate_limit_retries: 2
             )

    # initial attempt + 2 capped retries
    assert FakeAnthropic.calls(probe) == 3
    # escalating fallback pauses: 20ms then 40ms
    assert System.monotonic_time(:millisecond) - started >= 55
  end

  test "5xx retries with budget and succeeds within it", %{limiter: limiter} do
    probe =
      FakeAnthropic.install(__MODULE__, [{:status, 500, []}, {:status, 503, []}, {:text, "hello"}])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert FakeAnthropic.calls(probe) == 3

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 1},
                    %{reason: :server_error, limiter: ^limiter}}

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 2},
                    %{reason: :server_error, limiter: ^limiter}}
  end

  test "budget exhaustion returns the last error", %{limiter: limiter} do
    probe = FakeAnthropic.install(__MODULE__, [{:status, 500, []}])

    assert {:error, :server_error} =
             Request.infer(limiter, client(), "prompt", chunk_retries: 2, retry_backoff_ms: 1)

    # initial attempt + 2 budgeted retries
    assert FakeAnthropic.calls(probe) == 3
  end

  test "transport errors consume budget with :transport_error reason",
       %{limiter: limiter} do
    probe = FakeAnthropic.install(__MODULE__, [:transport_error, {:text, "hello"}])

    assert {:ok, "hello"} = Request.infer(limiter, client(), "prompt", @opts)
    assert FakeAnthropic.calls(probe) == 2

    assert_receive {[:lang_extract, :chunk, :retry], %{attempt: 1},
                    %{reason: :transport_error, limiter: ^limiter}}
  end

  test "4xx returns immediately without retrying", %{limiter: limiter} do
    probe = FakeAnthropic.install(__MODULE__, [{:status, 400, []}, {:text, "hello"}])

    assert {:error, {:bad_request, _}} = Request.infer(limiter, client(), "prompt", @opts)
    assert FakeAnthropic.calls(probe) == 1
    refute_receive {[:lang_extract, :chunk, :retry], _, %{limiter: ^limiter}}
  end

  test "in-flight slot is released between attempts" do
    # max_in_flight is 5; a request retrying 3 times would deadlock itself
    # if it held its slot across attempts on a max_in_flight: 1 limiter.
    tight_limiter = start_supervised!({Limiter, [max_in_flight: 1]}, id: :tight)
    FakeAnthropic.install(__MODULE__, [{:status, 500, []}, {:status, 500, []}, {:text, "hello"}])

    assert {:ok, "hello"} = Request.infer(tight_limiter, client(), "prompt", @opts)
  end
end
