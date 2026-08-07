defmodule LangExtract.Runner.LimiterTest do
  use ExUnit.Case, async: true

  alias LangExtract.Runner.Limiter
  alias LangExtract.Test.Telemetry

  defp attach_wait_telemetry do
    Telemetry.attach([[:lang_extract, :limiter, :wait]])
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

  # blocked_acquire is asynchronous: nothing orders one spawn's acquire
  # call ahead of the next one's. FIFO assertions need the earlier waiter
  # confirmed in the queue before spawning the later one.
  defp await_waiting(limiter, n) do
    %{waiting: waiting} = :sys.get_state(limiter)

    if :queue.len(waiting) < n do
      Process.sleep(1)
      await_waiting(limiter, n)
    else
      :ok
    end
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
      await_waiting(limiter, 1)
      fourth = blocked_acquire(limiter)
      refute_receive {:acquired, _}, 50

      send(first, :release)
      assert_receive {:acquired, ^third}
      refute_receive {:acquired, _}, 50

      send(second, :release)
      assert_receive {:acquired, ^fourth}

      assert_receive {[:lang_extract, :limiter, :wait], %{duration: d},
                      %{reason: :in_flight, limiter: ^limiter}}

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

      assert_receive {[:lang_extract, :limiter, :wait], _,
                      %{reason: :retry_after, limiter: ^limiter}}
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

    # retry-after is unauthenticated server input: proxies echoing an epoch
    # timestamp (a recurring server bug class) would otherwise hold every
    # caller for decades — and overflow the wake timer, crashing the
    # limiter. The ceiling turns garbage deadlines into a bounded stall.
    test "pauses clamp to the ceiling instead of trusting the deadline" do
      clock = start_supervised!({Agent, fn -> 0 end})
      clock_fun = fn -> Agent.get(clock, & &1) end
      limiter = start_supervised!({Limiter, [max_in_flight: 10, clock: clock_fun]})

      Limiter.pause(limiter, 1_000_000_000_000_000)
      # pause/2 is a cast; sync before moving the clock so the deadline
      # is computed from virtual time zero.
      _ = :sys.get_state(limiter)
      Agent.update(clock, fn _ -> 30_001 end)

      waiter = blocked_acquire(limiter)
      assert_receive {:acquired, ^waiter}, 500
    end

    # Under contention, pause/acquire paths used to stack send_after(:wake)
    # without canceling the previous timer. One outstanding ref is enough.
    test "rescheduling the wake timer cancels the previous one" do
      limiter = start_supervised!({Limiter, [max_in_flight: 10]})

      Limiter.pause(limiter, 60_000)
      waiter = blocked_acquire(limiter)
      await_waiting(limiter, 1)

      %{wake_ref: first_ref} = :sys.get_state(limiter)
      assert is_reference(first_ref)
      assert is_integer(Process.read_timer(first_ref))

      Limiter.pause(limiter, 60_000)
      %{wake_ref: second_ref} = :sys.get_state(limiter)

      assert is_reference(second_ref)
      assert is_integer(Process.read_timer(second_ref))
      # Previous timer is gone (cancelled or already delivered and cleared).
      assert Process.read_timer(first_ref) == false
      assert first_ref != second_ref

      # The waiter is blocked inside Limiter.acquire/1 and can't receive
      # messages; it dies when start_supervised!'s cleanup stops the
      # limiter and the call exits. Unlink so that exit can't cascade here.
      Process.unlink(waiter)
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

      assert_receive {[:lang_extract, :limiter, :wait], %{duration: 20_001},
                      %{reason: :rpm, limiter: ^limiter}}
    end

    # Tokens accrue on the clock, so a fresh acquire can land just after
    # a token the queue head's wake timer was about to claim. Serving the
    # newcomer first stole that token — under sustained arrivals the head
    # waiter's wait extended indefinitely (budget caps held; fairness
    # did not).
    test "a fresh acquirer queues behind an earlier waiter instead of stealing its token" do
      clock = start_supervised!({Agent, fn -> 0 end})
      clock_fun = fn -> Agent.get(clock, & &1) end
      limiter = start_supervised!({Limiter, [rpm: 1, max_in_flight: 10, clock: clock_fun]})

      :ok = Limiter.acquire(limiter)
      Limiter.release(limiter)

      waiter = blocked_acquire(limiter)
      refute_receive {:acquired, ^waiter}, 20

      # a token has accrued, but the waiter's wake timer hasn't fired
      Agent.update(clock, fn _ -> 60_001 end)
      newcomer = blocked_acquire(limiter)

      assert_receive {:acquired, ^waiter}, 500
      refute_receive {:acquired, ^newcomer}, 50
    end

    test "refill carries the fractional remainder instead of discarding it" do
      clock = start_supervised!({Agent, fn -> 0 end})
      clock_fun = fn -> Agent.get(clock, & &1) end

      limiter = start_supervised!({Limiter, [rpm: 3, max_in_flight: 10, clock: clock_fun]})

      # Drain the initial burst.
      for _ <- 1..3 do
        acquirer = blocked_acquire(limiter)
        assert_receive {:acquired, ^acquirer}
      end

      # 30 virtual seconds at rpm 3 earns 1.5 tokens: one grants now, the
      # half token must carry into the next refill.
      Agent.update(clock, fn _ -> 30_000 end)
      first = blocked_acquire(limiter)
      assert_receive {:acquired, ^first}

      second = blocked_acquire(limiter)
      refute_receive {:acquired, _}, 50

      # 15 more seconds earns 0.75 — only enough with the carried half.
      Agent.update(clock, fn _ -> 45_000 end)
      send(limiter, :wake)

      assert_receive {:acquired, ^second}
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
