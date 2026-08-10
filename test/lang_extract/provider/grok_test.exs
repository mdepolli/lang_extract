defmodule LangExtract.Provider.GrokTest do
  # async: false - these tests exercise the env-var fallback by mutating
  # global API-key vars; running concurrently with any env-reading test
  # would be flaky by design.
  use ExUnit.Case, async: false

  alias LangExtract.Provider.Grok

  describe "build_request/2" do
    setup do
      original = System.get_env("XAI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("XAI_API_KEY", original),
          else: System.delete_env("XAI_API_KEY")
      end)

      :ok
    end

    test "builds correct request with default opts" do
      assert {:ok, {req, request_opts}} = Grok.build_request("prompt", api_key: "xai-test")

      assert request_opts[:url] == "/v1/chat/completions"
      assert req.options.base_url == "https://api.x.ai"

      body = request_opts[:json]
      assert body["model"] == "grok-4.5"
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
      assert {:ok, {_req, request_opts}} =
               Grok.build_request("prompt",
                 api_key: "xai-test",
                 model: "grok-3",
                 max_tokens: 1024,
                 temperature: 0
               )

      body = request_opts[:json]
      assert body["model"] == "grok-3"
      assert body["max_completion_tokens"] == 1024
      assert body["temperature"] == 0
    end

    test "json_mode false omits response_format and system message" do
      assert {:ok, {_req, request_opts}} =
               Grok.build_request("Tell me a story.", api_key: "xai-test", json_mode: false)

      body = request_opts[:json]
      refute Map.has_key?(body, "response_format")
      assert body["messages"] == [%{"role" => "user", "content" => "Tell me a story."}]
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("XAI_API_KEY", "xai-env")

      assert {:ok, {req, _request_opts}} = Grok.build_request("prompt", api_key: "xai-opts")

      assert req.headers["authorization"] == ["Bearer xai-opts"]
    end

    test "falls back to XAI_API_KEY env var" do
      System.put_env("XAI_API_KEY", "xai-env")
      assert {:ok, {req, _request_opts}} = Grok.build_request("prompt", [])
      assert req.headers["authorization"] == ["Bearer xai-env"]
    end

    test "returns error when api key is missing" do
      System.delete_env("XAI_API_KEY")
      assert {:error, :missing_api_key} = Grok.build_request("prompt", [])
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
