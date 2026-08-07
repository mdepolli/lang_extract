defmodule LangExtract.Runner.Limiter do
  @moduledoc """
  The runner's shared request budget: an RPM token bucket plus an in-flight
  cap, with global backoff on `retry-after`.

  Chunk tasks call `acquire/2` before each HTTP request and `release/1`
  after it completes. Acquirers are monitored — a killed task (stream halt,
  crash) releases its slot automatically, so budget can never leak.
  `pause/2` holds *all* admission until a deadline: one 429 informs every
  in-flight chunk instead of N requests independently colliding with the
  same exhausted window.

  Emits `[:lang_extract, :limiter, :wait]` whenever an acquire had to wait,
  with the wait `duration`, the `reason` that blocked it first
  (`:rpm` | `:in_flight` | `:retry_after`), and the `limiter` pid.

  Tokens refill lazily from elapsed time — no timer ticks. The clock is
  injectable (`:clock`, a zero-arity fun returning milliseconds) so tests
  run on virtual time.

  Internal — no stability guarantees; see the README's "Stability"
  section. Documented because it explains how the library works, not
  because it is API.
  """

  use GenServer

  # Ceiling on any single pause. A retry-after deadline is unauthenticated
  # server input — proxies echo epoch timestamps into it — and obeying it
  # verbatim would hold every caller of a shared runner indefinitely (and
  # overflow the wake timer). Persistent throttling still stalls admission:
  # each new 429 re-pauses, extending the deadline another window.
  @max_pause_ms 30_000

  @type option ::
          {:rpm, pos_integer() | :infinity}
          | {:max_in_flight, pos_integer()}
          | {:clock, (-> integer())}
          | {:name, GenServer.name()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Blocks until a request slot and a token are granted.

  Returns `:ok`. The caller is monitored until it calls `release/1` (or
  dies, which releases implicitly).
  """
  @spec acquire(GenServer.server(), timeout()) :: :ok
  def acquire(limiter, timeout \\ :infinity) do
    GenServer.call(limiter, :acquire, timeout)
  end

  @doc "Releases the caller's in-flight slot after its request completes."
  @spec release(GenServer.server()) :: :ok
  def release(limiter) do
    GenServer.cast(limiter, {:release, self()})
  end

  @doc """
  Pauses all admission for `ms` milliseconds (a `retry-after` deadline).

  Repeated pauses extend to the furthest deadline; they never shorten it.
  A single pause is clamped to a 30-second ceiling — repeated 429s extend
  it window by window, but no one header value can stall a run for hours.
  """
  @spec pause(GenServer.server(), non_neg_integer()) :: :ok
  def pause(limiter, ms) do
    GenServer.cast(limiter, {:pause, ms})
  end

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    rpm = Keyword.get(opts, :rpm, :infinity)

    {:ok,
     %{
       clock: clock,
       rpm: rpm,
       max_in_flight: Keyword.get(opts, :max_in_flight, 10),
       tokens: initial_tokens(rpm),
       refilled_at: clock.(),
       pause_until: nil,
       # pid => monitor ref, for explicit release and DOWN auto-release
       in_flight: %{},
       # queued acquires: {from, enqueued_at, first_block_reason}
       waiting: :queue.new()
     }}
  end

  defp initial_tokens(:infinity), do: :infinity
  defp initial_tokens(rpm), do: rpm

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    # Serve the queue before the newcomer: tokens accrue on the clock, so
    # this call can arrive just after a token the queue head's wake timer
    # was about to claim — granting the newcomer directly would steal it,
    # and under sustained fresh arrivals the head's wait never ends.
    # admit_waiting refills, drains in FIFO order, and re-arms the wake
    # timer for a still-blocked head.
    state = admit_waiting(state)

    case admit_check(state) do
      :ok ->
        {:reply, :ok, grant(state, pid)}

      {:blocked, reason} ->
        entry = {from, state.clock.(), reason}
        state = %{state | waiting: :queue.in(entry, state.waiting)}
        {:noreply, schedule_wake(state)}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {:noreply, state |> drop_in_flight(pid) |> admit_waiting()}
  end

  def handle_cast({:pause, ms}, state) do
    deadline = state.clock.() + min(ms, @max_pause_ms)

    # No `|| 0` floor here: monotonic time can be (and on the BEAM, is)
    # negative, which would make 0 a far-future deadline.
    pause_until =
      case state.pause_until do
        nil -> deadline
        current -> max(deadline, current)
      end

    {:noreply, schedule_wake(%{state | pause_until: pause_until})}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, state |> drop_in_flight(pid) |> admit_waiting()}
  end

  def handle_info(:wake, state) do
    {:noreply, admit_waiting(state)}
  end

  defp admit_check(state) do
    now = state.clock.()

    cond do
      state.pause_until != nil and now < state.pause_until -> {:blocked, :retry_after}
      map_size(state.in_flight) >= state.max_in_flight -> {:blocked, :in_flight}
      state.tokens != :infinity and state.tokens < 1 -> {:blocked, :rpm}
      true -> :ok
    end
  end

  defp grant(state, pid) do
    ref = Process.monitor(pid)

    %{
      state
      | in_flight: Map.put(state.in_flight, pid, ref),
        tokens: spend_token(state.tokens)
    }
  end

  defp spend_token(:infinity), do: :infinity
  defp spend_token(tokens), do: tokens - 1

  defp drop_in_flight(state, pid) do
    case Map.pop(state.in_flight, pid) do
      {nil, _} ->
        state

      {ref, in_flight} ->
        Process.demonitor(ref, [:flush])
        %{state | in_flight: in_flight}
    end
  end

  # Grants queued acquires in FIFO order while the budget allows, emitting
  # the wait telemetry for each one that had been blocked.
  defp admit_waiting(state) do
    state = refill(clear_expired_pause(state))

    case :queue.out(state.waiting) do
      {:empty, _} ->
        state

      {{:value, {from, enqueued_at, reason}}, rest} ->
        case admit_check(state) do
          :ok ->
            {pid, _tag} = from

            # The limiter pid identifies which runner waited — same contract
            # as the chunk retry event, and what lets tests filter events
            # from concurrent suites.
            :telemetry.execute(
              [:lang_extract, :limiter, :wait],
              %{duration: state.clock.() - enqueued_at},
              %{reason: reason, limiter: self()}
            )

            GenServer.reply(from, :ok)

            %{state | waiting: rest}
            |> grant(pid)
            |> admit_waiting()

          {:blocked, _reason} ->
            schedule_wake(state)
        end
    end
  end

  defp clear_expired_pause(%{pause_until: nil} = state), do: state

  defp clear_expired_pause(state) do
    if state.clock.() >= state.pause_until do
      %{state | pause_until: nil}
    else
      state
    end
  end

  # Lazy token-bucket refill: rpm tokens per 60s of elapsed clock, capped
  # at rpm (one window of burst).
  defp refill(%{rpm: :infinity} = state), do: state

  defp refill(state) do
    now = state.clock.()
    elapsed = now - state.refilled_at
    earned = elapsed * state.rpm / 60_000

    cond do
      earned < 1 ->
        state

      state.tokens + trunc(earned) >= state.rpm ->
        # Bucket full: overflow is discarded, fraction included.
        %{state | tokens: state.rpm, refilled_at: now}

      true ->
        # Backdate refilled_at by the unearned fraction so partial tokens
        # carry into the next refill instead of being discarded each time.
        leftover_ms = round((earned - trunc(earned)) * 60_000 / state.rpm)
        %{state | tokens: state.tokens + trunc(earned), refilled_at: now - leftover_ms}
    end
  end

  # Waiting acquires need a future wake-up when blocked on time (pause
  # deadline or token refill) rather than on a release event.
  defp schedule_wake(state) do
    delay = if :queue.is_empty(state.waiting), do: nil, else: wake_delay(state)

    if delay do
      Process.send_after(self(), :wake, max(delay, 1))
    end

    state
  end

  defp wake_delay(state) do
    now = state.clock.()

    [
      state.pause_until && state.pause_until - now,
      state.rpm != :infinity && state.tokens < 1 && next_token_ms(state, now)
    ]
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp next_token_ms(state, now) do
    elapsed = now - state.refilled_at
    ceil(60_000 / state.rpm - elapsed)
  end
end
