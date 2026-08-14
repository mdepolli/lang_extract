defmodule LangExtract.Provider.ClaudeTest do
  # async: false - the build_http_client tests exercise the env-var
  # fallback by mutating global API-key vars; running concurrently with
  # any env-reading test would be flaky by design.
  use ExUnit.Case, async: false

  alias LangExtract.Provider.Claude

  # Payload assertions go through the real door: build a client, run
  # infer, and capture the request exactly as the server receives it.
  defp captured_request(prompt, opts) do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      body = Req.Test.raw_body(conn)
      send(parent, {:request, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
    end)

    client =
      LangExtract.new(
        :claude,
        [api_key: "sk-test", req_options: [plug: {Req.Test, __MODULE__}]] ++ opts
      )

    {:ok, _} = Claude.infer(client, prompt)
    assert_receive {:request, path, json}
    {path, json}
  end

  describe "the inference request on the wire" do
    test "builds correct request with default opts" do
      {url, body} = captured_request("Extract entities.", [])

      assert url == "/v1/messages"
      assert body["model"] == "claude-sonnet-5"
      assert body["max_tokens"] == 4096
      refute Map.has_key?(body, "temperature")
      assert body["messages"] == [%{"role" => "user", "content" => "Extract entities."}]
    end

    test "temperature is sent only when explicitly set" do
      {_url, body} = captured_request("prompt", temperature: 0)
      assert body["temperature"] == 0
    end

    test "custom opts override defaults" do
      {_url, body} =
        captured_request("prompt",
          model: "claude-opus-4-20250514",
          max_tokens: 1024,
          temperature: 0.5
        )

      assert body["model"] == "claude-opus-4-20250514"
      assert body["max_tokens"] == 1024
      assert body["temperature"] == 0.5
    end
  end

  describe "build_http_client/1" do
    setup do
      original = System.get_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("ANTHROPIC_API_KEY", original),
          else: System.delete_env("ANTHROPIC_API_KEY")
      end)

      :ok
    end

    test "builds the transport with defaults and auth" do
      assert {:ok, req} = Claude.build_http_client(api_key: "sk-test")

      assert req.options.base_url == "https://api.anthropic.com"
      assert req.options.receive_timeout == 120_000
      assert req.options.retry == :transient
      assert req.headers["x-api-key"] == ["sk-test"]
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, req} = Claude.build_http_client(api_key: "sk-opts")

      assert req.headers["x-api-key"] == ["sk-opts"]
    end

    test "falls back to ANTHROPIC_API_KEY env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, req} = Claude.build_http_client([])

      assert req.headers["x-api-key"] == ["sk-env"]
    end

    test "returns error when api key is missing" do
      System.delete_env("ANTHROPIC_API_KEY")
      assert {:error, :missing_api_key} = Claude.build_http_client([])
    end

    test "returns error when api key is empty string" do
      System.put_env("ANTHROPIC_API_KEY", "")
      assert {:error, :missing_api_key} = Claude.build_http_client([])
    end

    test "req_options override HTTP defaults" do
      assert {:ok, req} =
               Claude.build_http_client(
                 api_key: "sk-test",
                 req_options: [receive_timeout: 5_000, retry: false]
               )

      assert req.options.receive_timeout == 5_000
      assert req.options.retry == false
    end

    test "custom base_url is used" do
      assert {:ok, req} =
               Claude.build_http_client(api_key: "sk-test", base_url: "https://proxy.example.com")

      assert req.options.base_url == "https://proxy.example.com"
    end
  end

  describe "parse_response/1" do
    test "extracts text from successful response" do
      response = %Req.Response{
        status: 200,
        body: %{"content" => [%{"type" => "text", "text" => "extracted entities here"}]}
      }

      assert {:ok, "extracted entities here"} = Claude.parse_response({:ok, response})
    end

    test "extracts first text block from multiple content blocks" do
      response = %Req.Response{
        status: 200,
        body: %{
          "content" => [
            %{"type" => "thinking", "thinking" => "let me reason..."},
            %{"type" => "text", "text" => "the actual response"}
          ]
        }
      }

      assert {:ok, "the actual response"} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when no text content blocks" do
      response = %Req.Response{
        status: 200,
        body: %{"content" => [%{"type" => "thinking", "thinking" => "hmm"}]}
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when content is empty" do
      response = %Req.Response{status: 200, body: %{"content" => []}}
      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when body has no content key" do
      response = %Req.Response{status: 200, body: %{"something" => "else"}}
      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when body is not a map" do
      response = %Req.Response{status: 200, body: "not json"}
      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    # Decoded bodies flatten to a bounded preview string (see
    # Provider.body_preview/1); the server's message must survive into it.
    test "maps HTTP 400 to bad_request with a bounded body preview" do
      response = %Req.Response{
        status: 400,
        body: %{"error" => %{"message" => "invalid model"}}
      }

      assert {:error, {:bad_request, preview}} = Claude.parse_response({:ok, response})
      assert is_binary(preview)
      assert preview =~ "invalid model"
    end

    test "maps HTTP 401 to unauthorized" do
      response = %Req.Response{status: 401, body: %{}}
      assert {:error, :unauthorized} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %Req.Response{status: 429, body: %{}}
      assert {:error, {:rate_limited, nil}} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %Req.Response{status: 500, body: %{}}
      assert {:error, :server_error} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 503 to server_error" do
      response = %Req.Response{status: 503, body: %{}}
      assert {:error, :server_error} = Claude.parse_response({:ok, response})
    end

    test "maps other HTTP errors to api_error" do
      response = %Req.Response{status: 418, body: %{"error" => "teapot"}}
      assert {:error, {:api_error, 418, _}} = Claude.parse_response({:ok, response})
    end

    test "maps transport error to request_error" do
      error = %Mint.TransportError{reason: :timeout}

      assert {:error, {:request_error, %Mint.TransportError{reason: :timeout}}} =
               Claude.parse_response({:error, error})
    end
  end
end
