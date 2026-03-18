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
      assert {:ok, {client, path, request_opts}} =
               Claude.build_request("Extract entities.", api_key: "sk-test")

      assert path == "/v1/messages"
      assert client.base_url == "https://api.anthropic.com"

      body = request_opts[:json]
      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["max_tokens"] == 4096
      assert body["temperature"] == 0
      assert body["messages"] == [%{"role" => "user", "content" => "Extract entities."}]
    end

    test "custom opts override defaults" do
      assert {:ok, {_client, _path, request_opts}} =
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

      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt", api_key: "sk-opts")

      assert client.options[:headers]["x-api-key"] == "sk-opts"
    end

    test "falls back to ANTHROPIC_API_KEY env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt", [])

      assert client.options[:headers]["x-api-key"] == "sk-env"
    end

    test "returns error when api key is missing" do
      System.delete_env("ANTHROPIC_API_KEY")

      assert {:error, :missing_api_key} = Claude.build_request("prompt", [])
    end

    test "custom base_url is used" do
      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt",
                 api_key: "sk-test",
                 base_url: "https://proxy.example.com"
               )

      assert client.base_url == "https://proxy.example.com"
    end
  end

  describe "parse_response/1" do
    test "extracts text from successful response" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "content" => [%{"type" => "text", "text" => "extracted entities here"}]
        }
      }

      assert {:ok, "extracted entities here"} = Claude.parse_response({:ok, response})
    end

    test "extracts first text block from multiple content blocks" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
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
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"content" => [%{"type" => "thinking", "thinking" => "hmm"}]}
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when content is empty" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"content" => []}
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when body has no content key" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"something" => "else"}
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "returns empty_response when body is not a map" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: "not json"
      }

      assert {:error, :empty_response} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request with body" do
      response = %HTTPower.Response{
        status: 400,
        headers: %{},
        body: %{"error" => %{"message" => "invalid model"}}
      }

      assert {:error, {:bad_request, %{"error" => _}}} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %HTTPower.Response{status: 401, headers: %{}, body: %{}}
      assert {:error, :unauthorized} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %HTTPower.Response{status: 429, headers: %{}, body: %{}}
      assert {:error, :rate_limited} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %HTTPower.Response{status: 500, headers: %{}, body: %{}}
      assert {:error, :server_error} = Claude.parse_response({:ok, response})
    end

    test "maps HTTP 503 to server_error" do
      response = %HTTPower.Response{status: 503, headers: %{}, body: %{}}
      assert {:error, :server_error} = Claude.parse_response({:ok, response})
    end

    test "maps other HTTP errors to api_error" do
      response = %HTTPower.Response{status: 418, headers: %{}, body: %{"error" => "teapot"}}
      assert {:error, {:api_error, 418, _}} = Claude.parse_response({:ok, response})
    end

    test "maps HTTPower error to request_error" do
      error = %HTTPower.Error{reason: :timeout, message: "Request timeout"}
      assert {:error, {:request_error, :timeout}} = Claude.parse_response({:error, error})
    end

    test "maps connection refused to request_error" do
      error = %HTTPower.Error{reason: :econnrefused, message: "Connection refused"}
      assert {:error, {:request_error, :econnrefused}} = Claude.parse_response({:error, error})
    end
  end

  describe "infer/2" do
    setup do
      HTTPower.Test.setup()
    end

    test "full pipeline returns extracted text" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "extracted entities"}]
        })
      end)

      assert {:ok, "extracted entities"} = Claude.infer("Extract entities.", api_key: "sk-test")
    end

    test "returns error on missing api key" do
      assert {:error, :missing_api_key} = Claude.infer("prompt")
    end
  end
end
