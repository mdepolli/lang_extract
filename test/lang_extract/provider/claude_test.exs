defmodule LangExtract.Provider.ClaudeTest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.Claude

  describe "build_request/2" do
    setup do
      original = System.get_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("ANTHROPIC_API_KEY", original),
          else: System.delete_env("ANTHROPIC_API_KEY")
      end)

      :ok
    end

    test "builds correct request with default opts" do
      assert {:ok, {req, request_opts}} =
               Claude.build_request("Extract entities.", api_key: "sk-test")

      assert request_opts[:url] == "/v1/messages"
      assert req.options.base_url == "https://api.anthropic.com"

      body = request_opts[:json]
      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["max_tokens"] == 4096
      assert body["temperature"] == 0
      assert body["messages"] == [%{"role" => "user", "content" => "Extract entities."}]
    end

    test "custom opts override defaults" do
      assert {:ok, {_req, request_opts}} =
               Claude.build_request("prompt",
                 api_key: "sk-test",
                 model: "claude-opus-4-20250514",
                 max_tokens: 1024,
                 temperature: 0.5
               )

      body = request_opts[:json]
      assert body["model"] == "claude-opus-4-20250514"
      assert body["max_tokens"] == 1024
      assert body["temperature"] == 0.5
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, {req, _request_opts}} =
               Claude.build_request("prompt", api_key: "sk-opts")

      assert req.headers["x-api-key"] == ["sk-opts"]
    end

    test "falls back to ANTHROPIC_API_KEY env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, {req, _request_opts}} =
               Claude.build_request("prompt", [])

      assert req.headers["x-api-key"] == ["sk-env"]
    end

    test "returns error when api key is missing" do
      System.delete_env("ANTHROPIC_API_KEY")
      assert {:error, :missing_api_key} = Claude.build_request("prompt", [])
    end

    test "returns error when api key is empty string" do
      System.put_env("ANTHROPIC_API_KEY", "")
      assert {:error, :missing_api_key} = Claude.build_request("prompt", [])
    end

    test "custom base_url is used" do
      assert {:ok, {req, _request_opts}} =
               Claude.build_request("prompt",
                 api_key: "sk-test",
                 base_url: "https://proxy.example.com"
               )

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

    test "maps HTTP 400 to bad_request with body" do
      response = %Req.Response{
        status: 400,
        body: %{"error" => %{"message" => "invalid model"}}
      }

      assert {:error, {:bad_request, %{"error" => _}}} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %Req.Response{status: 401, body: %{}}
      assert {:error, :unauthorized} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %Req.Response{status: 429, body: %{}}
      assert {:error, :rate_limited} = Claude.parse_response({:ok, response})
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

  describe "infer/2" do
    test "full pipeline returns extracted text" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "extracted entities"}]
        })
      end)

      assert {:ok, "extracted entities"} =
               Claude.infer("Extract entities.",
                 api_key: "sk-test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "returns error on missing api key" do
      assert {:error, :missing_api_key} = Claude.infer("prompt")
    end
  end
end
