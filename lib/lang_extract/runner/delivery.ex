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

  ## Drain

  When the runner shuts down mid-stream (deploy, supervisor restart),
  chunk tasks trap exits, so the supervisor's shutdown signal gives each
  in-flight request up to `:shutdown` milliseconds to finish naturally —
  completed results still reach the consumer. Chunks never started are
  emitted as `{:error, %ChunkError{reason: :drained}}`, detected when
  admission hits the dead task supervisor. Consumers already handle
  per-chunk errors, so drain adds no new consumer code paths.
  """

  alias LangExtract.Chunker.Chunk
  alias LangExtract.Pipeline.{ChunkError, ChunkResult}

  @type event :: {:ok, ChunkResult.t()} | {:error, ChunkError.t()}

  @spec stream_events(Supervisor.supervisor(), [Chunk.t()], (Chunk.t() -> term()), keyword()) ::
          Enumerable.t()
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
    cond do
      pending == [] ->
        {:halt, state}

      draining? ->
        [chunk | rest] = pending
        {[drained_event(chunk)], %{state | pending: rest}}

      # Admission was deferred (fresh state after all tasks resolved);
      # buffer is a pos_integer, so admit/1 either starts a task, drains,
      # or empties pending — the recursion terminates.
      true ->
        next(admit(state))
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

  defp to_event(chunk, {:ok, spans}) do
    {:ok, %ChunkResult{byte_start: chunk.byte_start, byte_end: chunk.byte_end, spans: spans}}
  end

  defp to_event(_chunk, {:error, %ChunkError{} = error}), do: {:error, error}

  defp crash_event(chunk, reason) do
    {:error,
     %ChunkError{
       byte_start: chunk.byte_start,
       byte_end: chunk.byte_end,
       reason: {:task_exit, reason}
     }}
  end

  defp drained_event(chunk) do
    {:error,
     %ChunkError{byte_start: chunk.byte_start, byte_end: chunk.byte_end, reason: :drained}}
  end
end
