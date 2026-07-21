defmodule LangExtract.Runner.ChaosTest do
  @moduledoc """
  Scripted adversity against a full Runner, via the fake-Anthropic plug:
  429 storms, malformed payloads, shutdown mid-corpus. Doubles as the
  runner's integration suite.
  """
  use ExUnit.Case, async: true

  alias LangExtract.{ChunkError, ChunkResult}
  alias LangExtract.Result
  alias LangExtract.Runner
  alias LangExtract.Test.FakeAnthropic

  # Two sentences -> two chunks at max_chunk_chars: 25.
  @source "First sentence here. Second sentence there."
  @chunk_opts [max_chunk_chars: 25]

  defp client do
    LangExtract.new(:claude,
      api_key: "sk-test",
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp template, do: LangExtract.template!("Extract words.")

  test "one 429 pauses the whole runner until the retry-after deadline" do
    probe =
      FakeAnthropic.install(__MODULE__, [
        {:status, 429, [{"retry-after", "1"}]},
        {:ok, []}
      ])

    runner = start_supervised!({Runner, [client: client(), max_in_flight: 2]})

    assert %Result{spans: [], errors: []} =
             Runner.run(runner, @source, template(), @chunk_opts)

    # 2 chunks + 1 retried request; the retry waited out the global pause.
    assert FakeAnthropic.calls(probe) == 3
    times = FakeAnthropic.call_times(probe)
    assert List.last(times) - hd(times) >= 950
  end

  test "max_in_flight holds on the wire even with a wider buffer" do
    probe = FakeAnthropic.install(__MODULE__, [{:delay, 20, {:ok, []}}])

    six_sentences = String.duplicate("A sentence goes right here. ", 6)

    runner = start_supervised!({Runner, [client: client(), max_in_flight: 2, buffer: 5]})

    assert %Result{spans: [], errors: []} =
             Runner.run(runner, six_sentences, template(), max_chunk_chars: 25)

    assert FakeAnthropic.calls(probe) >= 6
    assert FakeAnthropic.max_concurrency(probe) <= 2
  end

  test "a permanently throttled endpoint fails the chunk instead of looping" do
    probe = FakeAnthropic.install(__MODULE__, [{:status, 429, []}])

    runner =
      start_supervised!({Runner, [client: client(), retry_backoff_ms: 1, rate_limit_retries: 2]})

    assert %Result{spans: [], errors: [%ChunkError{reason: {:rate_limited, nil}}]} =
             Runner.run(runner, "hello world", template())

    # initial + 2 capped retries, then the chunk gave up.
    assert FakeAnthropic.calls(probe) == 3
  end

  test "malformed payloads become per-chunk errors while neighbors succeed" do
    FakeAnthropic.install(__MODULE__, [
      {:text, "not json {{{"},
      {:ok, [%{"word" => "Second"}]}
    ])

    runner = start_supervised!({Runner, [client: client()]})

    assert %Result{spans: spans, errors: [%ChunkError{reason: {:invalid_format, _}}]} =
             Runner.run(runner, @source, template(), @chunk_opts)

    assert [%{text: "Second"}] = spans
  end

  test "shutdown mid-corpus: in-flight chunks finish, unstarted chunks drain" do
    FakeAnthropic.install(__MODULE__, [{:delay, 60, {:ok, []}}], notify: self())

    six_sentences = String.duplicate("A sentence goes right here. ", 6)
    expected = length(LangExtract.Chunker.chunk(six_sentences, max_chunk_chars: 25))

    runner_id = :drain_runner

    runner =
      start_supervised!(
        {Runner, [client: client(), max_in_flight: 2, buffer: 2, drain_timeout: 2_000]},
        id: runner_id
      )

    consumer =
      Task.async(fn ->
        runner
        |> Runner.stream(six_sentences, template(), max_chunk_chars: 25)
        |> Enum.to_list()
      end)

    # Both initial chunks are on the wire (stub signals arrival); pull the plug.
    assert_receive {:fake_anthropic_request, _}, 1_000
    assert_receive {:fake_anthropic_request, _}, 1_000
    :ok = stop_supervised(runner_id)

    events = Task.await(consumer)

    completed = Enum.count(events, &match?({:ok, %ChunkResult{}}, &1))
    drained = Enum.count(events, &match?({:error, %ChunkError{reason: :drained}}, &1))

    task_exits =
      Enum.count(events, &match?({:error, %ChunkError{reason: {:task_exit, _}}}, &1))

    # No chunk is lost: every one is accounted for exactly once.
    assert length(events) == expected
    # The in-flight pair got its grace window and finished.
    assert completed >= 2
    # Chunks never started are reported as drained.
    assert drained >= 2
    # Every event is one of the three shutdown outcomes — completed,
    # drained, or killed mid-grace — nothing else and nothing lost.
    assert completed + drained + task_exits == expected

    byte_starts =
      events
      |> Enum.map(fn
        {:ok, %ChunkResult{byte_start: start}} -> start
        {:error, %ChunkError{byte_start: start}} -> start
      end)
      |> Enum.sort()

    assert length(Enum.uniq(byte_starts)) == expected
  end

  test "stream_corpus tags events by document id, lazily" do
    FakeAnthropic.install(__MODULE__, [{:ok, [%{"word" => "hello"}]}])

    runner = start_supervised!({Runner, [client: client()]})

    docs = [{:doc_a, "hello world"}, {:doc_b, "hello again"}]

    events =
      runner
      |> Runner.stream_corpus(docs, template())
      |> Enum.to_list()

    assert [{:doc_a, {:ok, %ChunkResult{}}}, {:doc_b, {:ok, %ChunkResult{}}}] = events
  end
end
