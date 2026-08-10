defmodule LangExtract.Provider.OpenAITest do
  # async: false - the build_http_client tests exercise the env-var
  # fallback by mutating global API-key vars; running concurrently with
  # any env-reading test would be flaky by design.
  use ExUnit.Case, async: false

  alias LangExtract.Provider.OpenAI

  describe "build_inference_request/2" do
    test "builds correct request with default opts" do
      # Pure: no api_key, no transport — the payload is data.
      {url, body} = OpenAI.build_inference_request("Extract entities.", [])

      assert url == "/v1/chat/completions"
      assert body["model"] == "gpt-4o-mini"
      # max_completion_tokens replaced max_tokens in chat completions;
      # reasoning models reject the deprecated key with a 400.
      assert body["max_completion_tokens"] == 4096
      refute Map.has_key?(body, "max_tokens")
      # No temperature default — o-series/reasoning models reject any
      # non-default temperature with a 400 (same stance as Claude).
      refute Map.has_key?(body, "temperature")
      assert body["response_format"] == %{"type" => "json_object"}

      [system_msg, user_msg] = body["messages"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "Respond with JSON."
      assert user_msg == %{"role" => "user", "content" => "Extract entities."}
    end

    test "temperature is sent only when explicitly set" do
      {_url, body} = OpenAI.build_inference_request("prompt", temperature: 0)
      assert body["temperature"] == 0

      {_url, body} =
        OpenAI.build_inference_request("prompt",
          model: "gpt-4o",
          max_tokens: 1024,
          temperature: 0.7
        )

      assert body["model"] == "gpt-4o"
      assert body["max_completion_tokens"] == 1024
      assert body["temperature"] == 0.7
    end

    test "reasoning model opts omit temperature and still use max_completion_tokens" do
      {_url, body} = OpenAI.build_inference_request("prompt", model: "o4-mini")

      assert body["model"] == "o4-mini"
      assert body["max_completion_tokens"] == 4096
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "max_tokens")
    end

    # Older OpenAI-compatible servers only know the deprecated key and
    # silently drop max_completion_tokens (their own default then
    # truncates replies mid-JSON); openai.com reasoning models 400 on the
    # deprecated key. No heuristic can pick per server, so the wire key
    # is an explicit option.
    test "token_limit_key: :max_tokens switches the wire key for compat endpoints" do
      {_url, body} =
        OpenAI.build_inference_request("prompt", max_tokens: 1024, token_limit_key: :max_tokens)

      assert body["max_tokens"] == 1024
      refute Map.has_key?(body, "max_completion_tokens")
    end

    test "unknown token_limit_key raises a named ArgumentError" do
      assert_raise ArgumentError, ~r/:token_limit_key must be/, fn ->
        OpenAI.build_inference_request("prompt", token_limit_key: :tokens)
      end
    end

    test "json_mode false omits response_format and system message" do
      {_url, body} = OpenAI.build_inference_request("Tell me a story.", json_mode: false)

      refute Map.has_key?(body, "response_format")
      assert body["messages"] == [%{"role" => "user", "content" => "Tell me a story."}]
    end
  end

  describe "build_http_client/1" do
    setup do
      original = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("OPENAI_API_KEY", original),
          else: System.delete_env("OPENAI_API_KEY")
      end)

      :ok
    end

    test "builds the transport with defaults and auth" do
      assert {:ok, req} = OpenAI.build_http_client(api_key: "sk-test")

      assert req.options.base_url == "https://api.openai.com"
      assert req.options.receive_timeout == 120_000
      assert req.options.retry == :transient
      assert req.headers["authorization"] == ["Bearer sk-test"]
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("OPENAI_API_KEY", "sk-env")

      assert {:ok, req} = OpenAI.build_http_client(api_key: "sk-opts")

      assert req.headers["authorization"] == ["Bearer sk-opts"]
    end

    test "falls back to OPENAI_API_KEY env var" do
      System.put_env("OPENAI_API_KEY", "sk-env")
      assert {:ok, req} = OpenAI.build_http_client([])
      assert req.headers["authorization"] == ["Bearer sk-env"]
    end

    test "returns error when api key is missing" do
      System.delete_env("OPENAI_API_KEY")
      assert {:error, :missing_api_key} = OpenAI.build_http_client([])
    end

    test "returns error when api key is empty string" do
      System.put_env("OPENAI_API_KEY", "")
      assert {:error, :missing_api_key} = OpenAI.build_http_client([])
    end

    test "custom base_url is used" do
      assert {:ok, req} =
               OpenAI.build_http_client(api_key: "sk-test", base_url: "http://localhost:11434")

      assert req.options.base_url == "http://localhost:11434"
    end
  end

  describe "parse_response/1" do
    test "extracts content from successful response" do
      response = %Req.Response{
        status: 200,
        body: %{
          "choices" => [
            %{"message" => %{"content" => "extracted data"}, "finish_reason" => "stop"}
          ]
        }
      }

      assert {:ok, "extracted data"} = OpenAI.parse_response({:ok, response})
    end

    test "extracts first choice from multiple choices" do
      response = %Req.Response{
        status: 200,
        body: %{
          "choices" => [
            %{"message" => %{"content" => "first"}, "finish_reason" => "stop"},
            %{"message" => %{"content" => "second"}, "finish_reason" => "stop"}
          ]
        }
      }

      assert {:ok, "first"} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when choices is empty" do
      response = %Req.Response{status: 200, body: %{"choices" => []}}
      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when content is nil" do
      response = %Req.Response{
        status: 200,
        body: %{"choices" => [%{"message" => %{"content" => nil}}]}
      }

      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when body has no choices" do
      response = %Req.Response{status: 200, body: %{}}
      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request" do
      response = %Req.Response{status: 400, body: %{"error" => "bad"}}
      assert {:error, {:bad_request, _}} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %Req.Response{status: 401, body: %{}}
      assert {:error, :unauthorized} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %Req.Response{status: 429, body: %{}}
      assert {:error, {:rate_limited, nil}} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %Req.Response{status: 500, body: %{}}
      assert {:error, :server_error} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 503 to server_error" do
      response = %Req.Response{status: 503, body: %{}}
      assert {:error, :server_error} = OpenAI.parse_response({:ok, response})
    end

    test "maps other HTTP status codes to api_error" do
      response = %Req.Response{status: 418, body: %{"error" => "teapot"}}
      assert {:error, {:api_error, 418, _}} = OpenAI.parse_response({:ok, response})
    end

    test "maps transport error to request_error" do
      error = %Mint.TransportError{reason: :timeout}

      assert {:error, {:request_error, %Mint.TransportError{}}} =
               OpenAI.parse_response({:error, error})
    end
  end
end
