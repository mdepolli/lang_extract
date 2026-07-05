defmodule LangExtract.Runner.Delivery do
  @moduledoc """
  Bounded delivery of supervised chunk results to a lazy caller-side stream.

  The consumer's demand drives admission: at most `buffer` tasks are
  outstanding, so the caller's mailbox never holds more than `buffer`
  undelivered results (plus their `:DOWN` notices). A slow consumer
  throttles admission instead of growing a mailbox — the normative
  bounded-delivery constraint from the production-pipeline design.

  Task crashes become per-chunk events via the monitor `:DOWN` reason;
  halting the stream early kills all outstanding tasks.
  """

  alias LangExtract.Chunker.Chunk
  alias LangExtract.Pipeline.{ChunkError, ChunkResult}

  @type event :: {:ok, ChunkResult.t()} | {:error, ChunkError.t()}

  @spec stream_events(Supervisor.supervisor(), [Chunk.t()], pos_integer(), (Chunk.t() -> term())) ::
          Enumerable.t()
  def stream_events(task_supervisor, chunks, buffer, process_fun) do
    Stream.resource(
      fn ->
        admit(%{
          sup: task_supervisor,
          pending: chunks,
          tasks: %{},
          buffer: buffer,
          process: process_fun
        })
      end,
      &next/1,
      &cleanup/1
    )
  end

  defp admit(%{pending: [chunk | rest], tasks: tasks, buffer: buffer} = state)
       when map_size(tasks) < buffer do
    task = Task.Supervisor.async_nolink(state.sup, fn -> state.process.(chunk) end)
    admit(%{state | pending: rest, tasks: Map.put(tasks, task.ref, {task, chunk})})
  end

  defp admit(state), do: state

  defp next(%{tasks: tasks} = state) when map_size(tasks) == 0, do: {:halt, state}

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
end
