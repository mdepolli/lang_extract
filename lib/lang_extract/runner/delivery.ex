defmodule LangExtract.Runner.Delivery do
  @moduledoc """
  Bounded delivery of supervised chunk results to a lazy caller-side stream.

  The consumer's demand drives admission: at most `:buffer` tasks are
  outstanding, so the caller's mailbox never holds more than `:buffer`
  undelivered results (plus their `:DOWN` notices). A slow consumer
  throttles admission instead of growing a mailbox — the normative
  bounded-delivery constraint from the production-pipeline design.

  Task crashes become per-chunk events via the monitor `:DOWN` reason;
  halting the stream early kills all outstanding tasks.

  ## Why hand-rolled

  Without drain, this module should collapse into
  `Task.Supervisor.async_stream_nolink(..., max_concurrency: buffer,
  ordered: false, zip_input_on_exit: true)` — the bounded/unordered/
  crash-to-event core duplicates it. Drain is what it can't express:
  reporting never-started chunks requires detecting the dead supervisor
  at admission time. Layering that detection on top was also considered
  and rejected: a `Stream.transform` can't catch the supervisor-down
  exit (it erupts between elements, inside the inner enumerable's
  reduction), so the wrapper needs continuation-driving via
  `Enumerable.reduce` plus OTP exit-shape matching plus reconstructing
  the never-started set by diffing observed byte ranges — more fragile
  than this explicit loop, and dependent on uncontracted stdlib event
  ordering. If drain semantics are ever dropped, delete this module in
  favor of `async_stream_nolink`.

  ## Drain

  When the runner shuts down mid-stream (deploy, supervisor restart),
  chunk tasks trap exits, so the supervisor's shutdown signal gives each
  in-flight request up to `:shutdown` milliseconds to finish naturally —
  completed results still reach the consumer. Chunks never started are
  emitted as `{:error, %ChunkError{reason: :drained}}`, detected when
  admission hits the dead task supervisor. Consumers already handle
  per-chunk errors, so drain adds no new consumer code paths.

  Internal — no stability guarantees; see the README's "Stability"
  section. Documented because it explains how the library works, not
  because it is API.
  """

  alias LangExtract.Chunker.Chunk
  alias LangExtract.{ChunkError, ChunkResult}

  @type event :: {:ok, ChunkResult.t()} | {:error, ChunkError.t()}

  @spec stream_events(
          Supervisor.supervisor(),
          [Chunk.t()],
          (Chunk.t() -> {:ok, ChunkResult.t()} | {:error, ChunkError.t()}),
          keyword()
        ) :: Enumerable.t()
  def stream_events(task_supervisor, chunks, process_fun, opts) do
    state = %{
      sup: task_supervisor,
      pending: chunks,
      tasks: %{},
      buffer: Keyword.fetch!(opts, :buffer),
      shutdown: Keyword.get(opts, :shutdown, 5_000),
      process: process_fun,
      draining?: false
    }

    Stream.resource(fn -> admit(state) end, &next/1, &cleanup/1)
  end

  defp admit(%{draining?: true} = state), do: state
  defp admit(%{pending: []} = state), do: state

  defp admit(%{tasks: tasks, buffer: buffer} = state) when map_size(tasks) >= buffer, do: state

  defp admit(%{pending: [chunk | rest]} = state) do
    case start_task(state, chunk) do
      {:ok, task} ->
        admit(%{state | pending: rest, tasks: Map.put(state.tasks, task.ref, {task, chunk})})

      :supervisor_down ->
        %{state | draining?: true}
    end
  end

  defp start_task(state, chunk) do
    process = state.process

    task =
      Task.Supervisor.async_nolink(
        state.sup,
        fn ->
          # Trapping exits lets an in-flight request finish naturally when
          # the runner shuts down: the supervisor's exit signal is held off
          # for up to :shutdown ms instead of killing the task mid-request.
          Process.flag(:trap_exit, true)
          process.(chunk)
        end,
        shutdown: state.shutdown
      )

    {:ok, task}
  catch
    :exit, _reason -> :supervisor_down
  end

  defp next(%{tasks: tasks, pending: pending, draining?: draining?} = state)
       when map_size(tasks) == 0 do
    # next/1 only ever sees a state that just left admit/1 or is already
    # draining, and admit/1 never stops with tasks empty, pending
    # non-empty, and draining? false — so one of these two arms always
    # matches. Anything else is an invariant breach; let cond raise.
    cond do
      pending == [] ->
        {:halt, state}

      draining? ->
        [chunk | rest] = pending
        {[drained_event(chunk)], %{state | pending: rest}}
    end
  end

  defp next(state) do
    receive do
      {ref, result} when is_map_key(state.tasks, ref) ->
        Process.demonitor(ref, [:flush])
        {{_task, chunk}, tasks} = Map.pop(state.tasks, ref)
        {[to_event(chunk, result)], admit(%{state | tasks: tasks})}

      {:DOWN, ref, :process, _pid, reason} when is_map_key(state.tasks, ref) ->
        {{_task, chunk}, tasks} = Map.pop(state.tasks, ref)
        {[crash_event(chunk, reason)], admit(%{state | tasks: tasks})}
    end
  end

  defp cleanup(state) do
    Enum.each(state.tasks, fn {_ref, {task, _chunk}} -> Task.shutdown(task, :brutal_kill) end)
  end

  defp to_event(_chunk, {:ok, %ChunkResult{} = result}), do: {:ok, result}
  defp to_event(_chunk, {:error, %ChunkError{} = error}), do: {:error, error}

  defp crash_event(chunk, reason) do
    {:error, ChunkError.from_chunk(chunk, {:task_exit, sanitize(reason)})}
  end

  # A raw exit reason can embed the crashing frame's arguments — including
  # the Req.Request whose headers hold the API key (Req's Inspect redacts
  # only `authorization`, and OTP crash logs bypass Inspect entirely) — so
  # the reason is reduced to a header-free summary before it becomes data.
  defp sanitize({reason, [{mod, fun, _args, _info} | _]}) when is_atom(mod) and is_atom(fun) do
    scrub(reason)
  end

  defp sanitize(reason), do: scrub(reason)

  defp scrub(reason) when is_atom(reason), do: reason

  defp scrub(exception) when is_exception(exception),
    do: Exception.format_banner(:error, exception)

  defp scrub(other), do: inspect(other, limit: 20, printable_limit: 256)

  defp drained_event(chunk) do
    {:error, ChunkError.from_chunk(chunk, :drained)}
  end
end
