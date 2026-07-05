defmodule LangExtract.RunnerTest do
  use ExUnit.Case, async: true

  alias LangExtract.Runner

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
