defmodule LangExtract.RunnerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Client
  alias LangExtract.Result
  alias LangExtract.Runner
  alias LangExtract.Test.FakeAnthropic

  defmodule RebuildFails do
    def build_http_client(_opts), do: {:error, :api_key_missing}
  end

  defp client do
    LangExtract.new(:claude,
      api_key: "sk-test",
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  describe "supervision" do
    test "starts config, limiter, and task supervisor; exposes them via resources/1" do
      runner = start_supervised!({Runner, [client: client(), max_in_flight: 7]})

      resources = Runner.resources(runner)

      assert is_pid(resources.limiter)
      assert is_pid(resources.task_supervisor)
      assert resources.config.chunk_retries == 3
      assert resources.config.retry_backoff_ms == 200
      # buffer defaults to max_in_flight
      assert resources.config.buffer == 7
    end

    test "disables Req retry for the runner's client, preserving other req_options" do
      runner = start_supervised!({Runner, [client: client()]})

      runner_client = Runner.resources(runner).config.client

      assert runner_client.http_client.options.retry == false
      assert runner_client.http_client.options.plug == {Req.Test, __MODULE__}
      # the original client is untouched
      assert client().http_client.options.retry == :transient
    end

    # buffer: 0 would otherwise reach Delivery's "impossible" admit state
    # and die as a bare CondClauseError deep in the consumer; rpm: 0
    # divides by zero in the limiter's refill arithmetic. Negative
    # chunk_retries never equals spent in retry_or_give_up → unbounded
    # 5xx retries; negative backoff crashes in Process.sleep mid-chunk.
    @tag :capture_log
    test "non-positive numeric options fail startup with a descriptive error" do
      Process.flag(:trap_exit, true)

      for {bad, pattern} <- [
            {[max_in_flight: 0], "positive integer"},
            {[buffer: 0], "positive integer"},
            {[rpm: 0], "positive integer"},
            {[buffer: -1], "positive integer"},
            {[retry_backoff_ms: 0], "positive integer"},
            {[retry_backoff_ms: -1], "positive integer"},
            {[chunk_retries: -1], "non-negative integer"},
            {[rate_limit_retries: -1], "non-negative integer"},
            {[drain_timeout: -1], "non-negative integer"}
          ] do
        assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
                 Runner.start_link([client: client()] ++ bad)

        [{key, value}] = bad
        assert message =~ "#{inspect(key)} must be a #{pattern}"
        assert message =~ "got: #{value}"
      end
    end

    test "zero chunk_retries and drain_timeout are accepted at startup" do
      runner =
        start_supervised!(
          {Runner, [client: client(), chunk_retries: 0, rate_limit_retries: 0, drain_timeout: 0]},
          id: :zero_ok
        )

      config = Runner.resources(runner).config
      assert config.chunk_retries == 0
      assert config.rate_limit_retries == 0
      assert config.drain_timeout == 0
    end

    @tag :capture_log
    test "a client that can't be rebuilt fails startup with a descriptive error" do
      broken = %Client{provider: RebuildFails, options: [], http_client: nil}
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Runner.start_link(client: broken)

      assert message =~ "failed to rebuild the client's HTTP client: :api_key_missing"
    end

    test "two runners coexist with independent budgets" do
      first = start_supervised!({Runner, [client: client(), max_in_flight: 1]}, id: :runner_one)

      second =
        start_supervised!({Runner, [client: client(), max_in_flight: 2]}, id: :runner_two)

      assert Runner.resources(first).limiter != Runner.resources(second).limiter
      assert Runner.resources(first).config.buffer == 1
      assert Runner.resources(second).config.buffer == 2
    end

    test "one_for_all: a crashed limiter restarts the whole cell" do
      runner = start_supervised!({Runner, [client: client()]})

      %{limiter: limiter, task_supervisor: task_sup} = Runner.resources(runner)

      ref = Process.monitor(task_sup)
      Process.exit(limiter, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task_sup, _}

      # supervisor brings the cell back with fresh children
      resources =
        eventually(fn ->
          %{limiter: new_limiter} = r = Runner.resources(runner)
          if Process.alive?(new_limiter), do: r
        end)

      assert resources.limiter != limiter
      assert resources.task_supervisor != task_sup
    end
  end

  describe "run/4 and stream/4" do
    @source "First sentence here. Second sentence there."

    defp word_stub do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        prompt = hd(Jason.decode!(body)["messages"])["content"]
        word = if prompt =~ "First", do: "First", else: "Second"
        FakeAnthropic.respond_ok(conn, [%{"word" => word}])
      end)
    end

    defp template, do: LangExtract.template("Extract words.")

    test "stream/4 yields chunk results through the shared budget" do
      word_stub()
      runner = start_supervised!({Runner, [client: client()]})

      events =
        runner
        |> Runner.stream(@source, template(), max_chunk_chars: 25)
        |> Enum.to_list()

      assert length(events) == 2

      texts =
        events
        |> Enum.flat_map(fn {:ok, result} -> result.spans end)
        |> Enum.map(& &1.text)
        |> Enum.sort()

      assert texts == ["First", "Second"]
    end

    test "run/4 collects and restores document order" do
      word_stub()
      runner = start_supervised!({Runner, [client: client()]})

      assert %Result{spans: spans, errors: [], usage: usage} =
               Runner.run(runner, @source, template(), max_chunk_chars: 25)

      assert Enum.map(spans, & &1.text) == ["First", "Second"]
      assert [%{byte_start: 0}, %{byte_start: second_start}] = spans
      assert second_start > 0

      # FakeAnthropic reports 10/10 per request; two chunks total 20/20.
      assert usage == %{input_tokens: 20, output_tokens: 20}
    end

    test "max_in_flight serializes requests even with a wider buffer" do
      concurrency = :atomics.new(2, [])

      Req.Test.stub(__MODULE__, fn conn ->
        current = :atomics.add_get(concurrency, 1, 1)
        previous_max = :atomics.get(concurrency, 2)
        if current > previous_max, do: :atomics.put(concurrency, 2, current)
        Process.sleep(20)
        :atomics.sub(concurrency, 1, 1)

        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => []})}
          ]
        })
      end)

      runner = start_supervised!({Runner, [client: client(), max_in_flight: 1, buffer: 4]})

      assert %Result{spans: [], errors: []} =
               Runner.run(runner, @source, template(), max_chunk_chars: 25)

      assert :atomics.get(concurrency, 2) == 1
    end

    test "a failing request retries through the runner's policy" do
      calls = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(__MODULE__, fn conn ->
        if Agent.get_and_update(calls, fn n -> {n, n + 1} end) == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(500, "{}")
        else
          Req.Test.json(conn, %{
            "content" => [
              %{
                "type" => "text",
                "text" => Jason.encode!(%{"extractions" => [%{"word" => "hello"}]})
              }
            ]
          })
        end
      end)

      runner =
        start_supervised!({Runner, [client: client(), retry_backoff_ms: 1]})

      assert %Result{spans: [span], errors: []} =
               Runner.run(runner, "hello world", template())

      assert span.text == "hello"
      assert Agent.get(calls, & &1) == 2
    end

    test "a chunk that exhausts its retry budget lands in chunk_errors" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, "{}")
      end)

      runner =
        start_supervised!({Runner, [client: client(), chunk_retries: 1, retry_backoff_ms: 1]})

      assert %Result{
               spans: [],
               errors: [%LangExtract.ChunkError{reason: :server_error}]
             } =
               Runner.run(runner, "hello world", template())
    end
  end

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      nil ->
        flunk("condition never became true")

      result ->
        result
    end
  end
end
