defmodule LangExtract.Runner.DeliveryTest do
  use ExUnit.Case, async: true

  alias LangExtract.Chunker.Chunk
  alias LangExtract.Pipeline.{ChunkError, ChunkResult}
  alias LangExtract.Runner.Delivery

  defp chunks(n) do
    for i <- 1..n do
      %Chunk{text: "chunk #{i}", byte_start: (i - 1) * 100, byte_end: i * 100}
    end
  end

  setup do
    %{sup: start_supervised!(Task.Supervisor)}
  end

  test "admission never exceeds the buffer", %{sup: sup} do
    counter = :atomics.new(2, [])

    process = fn _chunk ->
      current = :atomics.add_get(counter, 1, 1)
      previous_max = :atomics.get(counter, 2)
      if current > previous_max, do: :atomics.put(counter, 2, current)
      Process.sleep(15)
      :atomics.sub(counter, 1, 1)
      {:ok, []}
    end

    events =
      sup
      |> Delivery.stream_events(chunks(8), process, buffer: 2)
      # slow consumer: admission must stay bounded regardless
      |> Enum.map(fn event ->
        Process.sleep(5)
        event
      end)

    assert length(events) == 8
    assert :atomics.get(counter, 2) <= 2
  end

  test "every chunk arrives exactly once with its byte range", %{sup: sup} do
    process = fn chunk -> {:ok, [chunk.text]} end

    starts =
      sup
      |> Delivery.stream_events(chunks(10), process, buffer: 3)
      |> Enum.map(fn {:ok, %ChunkResult{} = result} -> result.byte_start end)
      |> Enum.sort()

    assert starts == Enum.map(0..9, &(&1 * 100))
  end

  test "a crashing task becomes a per-chunk task_exit error", %{sup: sup} do
    process = fn
      %Chunk{byte_start: 100} -> raise "boom"
      _chunk -> {:ok, []}
    end

    events = sup |> Delivery.stream_events(chunks(3), process, buffer: 3) |> Enum.to_list()

    assert [{:error, %ChunkError{byte_start: 100, reason: {:task_exit, {%RuntimeError{}, _}}}}] =
             Enum.filter(events, &match?({:error, _}, &1))

    assert events |> Enum.filter(&match?({:ok, _}, &1)) |> length() == 2
  end

  test "chunk-level errors pass through untouched", %{sup: sup} do
    error = %ChunkError{byte_start: 0, byte_end: 100, reason: :rate_limited}
    process = fn _chunk -> {:error, error} end

    assert [{:error, ^error}] =
             sup |> Delivery.stream_events(chunks(1), process, buffer: 1) |> Enum.to_list()
  end

  test "halting early kills all outstanding tasks", %{sup: sup} do
    process = fn
      %Chunk{byte_start: 0} -> {:ok, []}
      _chunk -> Process.sleep(60_000)
    end

    assert [_one] = sup |> Delivery.stream_events(chunks(6), process, buffer: 3) |> Enum.take(1)

    Process.sleep(50)
    assert Task.Supervisor.children(sup) == []
  end
end
