defmodule LangExtract.Runner.LimiterTest do
  use ExUnit.Case, async: true

  alias LangExtract.Runner.Limiter

  # Module-qualified capture, not an anonymous fn, so telemetry stores it
  # without the local-handler penalty; the parent pid travels as config.
  def forward_event(event, measurements, metadata, parent) do
    send(parent, {event, measurements, metadata})
  end

  defp attach_wait_telemetry do
    handler_id = "limiter-telemetry-#{inspect(self())}"

    :telemetry.attach(
      handler_id,
      [:lang_extract, :limiter, :wait],
      &__MODULE__.forward_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp blocked_acquire(limiter) do
    parent = self()

    spawn_link(fn ->
      Limiter.acquire(limiter)
      send(parent, {:acquired, self()})

      receive do
        :release -> Limiter.release(limiter)
        :die -> exit(:boom)
      end
    end)
  end

  describe "in-flight cap" do
    test "blocks past max_in_flight and admits FIFO on release" do
      attach_wait_telemetry()
      limiter = start_supervised!({Limiter, [max_in_flight: 2]})

      first = blocked_acquire(limiter)
      second = blocked_acquire(limiter)
      assert_receive {:acquired, ^first}
      assert_receive {:acquired, ^second}

      third = blocked_acquire(limiter)
      fourth = blocked_acquire(limiter)
      refute_receive {:acquired, _}, 50

      send(first, :release)
      assert_receive {:acquired, ^third}
      refute_receive {:acquired, _}, 50

      send(second, :release)
      assert_receive {:acquired, ^fourth}

      assert_receive {[:lang_extract, :limiter, :wait], %{duration: d}, %{reason: :in_flight}}
      assert d >= 0
    end

    test "a dead acquirer releases its slot without calling release" do
      limiter = start_supervised!({Limiter, [max_in_flight: 1]})

      first = blocked_acquire(limiter)
      assert_receive {:acquired, ^first}

      second = blocked_acquire(limiter)
      refute_receive {:acquired, _}, 50

      Process.unlink(first)
      send(first, :die)
      assert_receive {:acquired, ^second}
    end
  end

  describe "retry-after pause" do
    test "holds all admission until the deadline" do
      attach_wait_telemetry()
      limiter = start_supervised!({Limiter, [max_in_flight: 10]})

      Limiter.pause(limiter, 80)
      started = System.monotonic_time(:millisecond)

      waiter = blocked_acquire(limiter)
      refute_receive {:acquired, _}, 40

      assert_receive {:acquired, ^waiter}, 500
      assert System.monotonic_time(:millisecond) - started >= 70

      assert_receive {[:lang_extract, :limiter, :wait], _, %{reason: :retry_after}}
    end

    test "pauses extend to the furthest deadline, never shorten" do
      limiter = start_supervised!({Limiter, [max_in_flight: 10]})

      Limiter.pause(limiter, 120)
      Limiter.pause(limiter, 10)
      started = System.monotonic_time(:millisecond)

      waiter = blocked_acquire(limiter)
      assert_receive {:acquired, ^waiter}, 500
      assert System.monotonic_time(:millisecond) - started >= 100
    end
  end

  describe "rpm token bucket" do
    test "spends the burst, then refills on the (virtual) clock" do
      attach_wait_telemetry()
      clock = start_supervised!({Agent, fn -> 0 end})
      clock_fun = fn -> Agent.get(clock, & &1) end

      limiter = start_supervised!({Limiter, [rpm: 3, max_in_flight: 10, clock: clock_fun]})

      # Full bucket: three instant grants.
      for _ <- 1..3 do
        acquirer = blocked_acquire(limiter)
        assert_receive {:acquired, ^acquirer}
      end

      # Bucket empty: the fourth waits on :rpm.
      fourth = blocked_acquire(limiter)
      refute_receive {:acquired, _}, 50

      # One token earns every 20 virtual seconds at rpm 3.
      Agent.update(clock, fn _ -> 20_001 end)
      send(limiter, :wake)

      assert_receive {:acquired, ^fourth}
      assert_receive {[:lang_extract, :limiter, :wait], %{duration: 20_001}, %{reason: :rpm}}
    end

    test "rpm: :infinity never blocks on tokens" do
      limiter = start_supervised!({Limiter, [rpm: :infinity, max_in_flight: 100]})

      for _ <- 1..50 do
        acquirer = blocked_acquire(limiter)
        assert_receive {:acquired, ^acquirer}
      end
    end
  end
end
