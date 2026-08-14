defmodule LangExtract.Provider.GrokTest do
  # async: false - these tests exercise the env-var fallback by mutating
  # global API-key vars; running concurrently with any env-reading test
  # would be flaky by design.
  use ExUnit.Case, async: false

  alias LangExtract.Provider.Grok

  # Payload assertions go through the real door: build a client, run
  # infer, and capture the request exactly as the server receives it.
  defp captured_request(prompt, opts) do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      body = Req.Test.raw_body(conn)
      send(parent, {:request, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    client =
      LangExtract.new(
        :grok,
        [api_key: "xai-test", req_options: [plug: {Req.Test, __MODULE__}]] ++ opts
      )

    {:ok, _} = Grok.infer(client, prompt)
    assert_receive {:request, path, json}
    {path, json}
  end

  describe "the inference request on the wire" do
    test "builds correct request with default opts" do
      {url, body} = captured_request("prompt", [])

      assert url == "/v1/chat/completions"
      # Non-reasoning default: extraction is structured work that gains
      # nothing from extended reasoning — the reasoning variants cost
      # 4-5x the latency and ~3x the input tokens for identical :exact
      # grounding (smoke-timed 2026-08-10). Reasoning models remain one
      # `model:` override away.
      assert body["model"] == "grok-4.20-0309-non-reasoning"
      # xAI accepts the modern key natively — no token_limit_key needed.
      assert body["max_completion_tokens"] == 4096
      refute Map.has_key?(body, "max_tokens")
      # Two temperature-default removals (Claude, then OpenAI) taught this
      # codebase the lesson: send it only when the caller sets it.
      refute Map.has_key?(body, "temperature")
      assert body["response_format"] == %{"type" => "json_object"}

      [system_msg, user_msg] = body["messages"]
      assert system_msg == %{"role" => "system", "content" => "Respond with JSON."}
      assert user_msg == %{"role" => "user", "content" => "prompt"}
    end

    test "temperature is sent only when explicitly set" do
      {_url, body} =
        captured_request("prompt", model: "grok-3", max_tokens: 1024, temperature: 0)

      assert body["model"] == "grok-3"
      assert body["max_completion_tokens"] == 1024
      assert body["temperature"] == 0
    end

    test "json_mode false omits response_format and system message" do
      {_url, body} = captured_request("Tell me a story.", json_mode: false)

      refute Map.has_key?(body, "response_format")
      assert body["messages"] == [%{"role" => "user", "content" => "Tell me a story."}]
    end
  end

  describe "build_http_client/1" do
    setup do
      original = System.get_env("XAI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("XAI_API_KEY", original),
          else: System.delete_env("XAI_API_KEY")
      end)

      :ok
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("XAI_API_KEY", "xai-env")

      assert {:ok, req} = Grok.build_http_client(api_key: "xai-opts")

      assert req.headers["authorization"] == ["Bearer xai-opts"]
      assert req.options.base_url == "https://api.x.ai"
    end

    test "falls back to XAI_API_KEY env var" do
      System.put_env("XAI_API_KEY", "xai-env")
      assert {:ok, req} = Grok.build_http_client([])
      assert req.headers["authorization"] == ["Bearer xai-env"]
    end

    test "returns error when api key is missing" do
      System.delete_env("XAI_API_KEY")
      assert {:error, :missing_api_key} = Grok.build_http_client([])
    end
  end

  describe "parse_response/1" do
    test "extracts text from the OpenAI-shaped choices reply" do
      response = %Req.Response{
        status: 200,
        body: %{"choices" => [%{"message" => %{"content" => "extracted data"}}]}
      }

      assert {:ok, "extracted data"} = Grok.parse_response({:ok, response})
    end

    test "empty choices map to empty_response" do
      response = %Req.Response{status: 200, body: %{"choices" => []}}
      assert {:error, :empty_response} = Grok.parse_response({:ok, response})
    end
  end
end
