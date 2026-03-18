defmodule LangExtract.Provider.OpenAITest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.OpenAI

  describe "build_request/2" do
    setup do
      original = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("OPENAI_API_KEY", original),
          else: System.delete_env("OPENAI_API_KEY")
      end)

      :ok
    end

    test "builds correct request with default opts" do
      assert {:ok, {client, path, request_opts}} =
               OpenAI.build_request("Extract entities.", api_key: "sk-test")

      assert path == "/v1/chat/completions"
      assert client.base_url == "https://api.openai.com"
      assert client.options[:headers]["authorization"] == "Bearer sk-test"

      body = request_opts[:json]
      assert body["model"] == "gpt-4o-mini"
      assert body["max_tokens"] == 4096
      assert body["temperature"] == 0
      assert body["response_format"] == %{"type" => "json_object"}

      assert body["messages"] == [
               %{"role" => "system", "content" => "Respond with JSON."},
               %{"role" => "user", "content" => "Extract entities."}
             ]
    end

    test "json_mode false omits response_format and system message" do
      assert {:ok, {_client, _path, request_opts}} =
               OpenAI.build_request("Tell me a story.", api_key: "sk-test", json_mode: false)

      body = request_opts[:json]
      refute Map.has_key?(body, "response_format")
      assert body["messages"] == [%{"role" => "user", "content" => "Tell me a story."}]
    end

    test "custom model, max_tokens, and temperature override defaults" do
      assert {:ok, {_client, _path, request_opts}} =
               OpenAI.build_request("prompt",
                 api_key: "sk-test",
                 model: "gpt-4o",
                 max_tokens: 1024,
                 temperature: 0.7
               )

      body = request_opts[:json]
      assert body["model"] == "gpt-4o"
      assert body["max_tokens"] == 1024
      assert body["temperature"] == 0.7
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("OPENAI_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               OpenAI.build_request("prompt", api_key: "sk-opts")

      assert client.options[:headers]["authorization"] == "Bearer sk-opts"
    end

    test "falls back to OPENAI_API_KEY env var" do
      System.put_env("OPENAI_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               OpenAI.build_request("prompt", [])

      assert client.options[:headers]["authorization"] == "Bearer sk-env"
    end

    test "returns error when api key is missing" do
      System.delete_env("OPENAI_API_KEY")

      assert {:error, :missing_api_key} = OpenAI.build_request("prompt", [])
    end

    test "returns error when api key is empty string" do
      System.put_env("OPENAI_API_KEY", "")

      assert {:error, :missing_api_key} = OpenAI.build_request("prompt", [])
    end

    test "custom base_url is used" do
      assert {:ok, {client, _path, _request_opts}} =
               OpenAI.build_request("prompt",
                 api_key: "sk-test",
                 base_url: "https://proxy.example.com"
               )

      assert client.base_url == "https://proxy.example.com"
    end
  end

  describe "parse_response/1" do
    test "extracts content from successful response" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "extracted entities here"}}
          ]
        }
      }

      assert {:ok, "extracted entities here"} = OpenAI.parse_response({:ok, response})
    end

    test "extracts content from first choice when multiple choices present" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "choices" => [
            %{"message" => %{"content" => "first choice"}},
            %{"message" => %{"content" => "second choice"}}
          ]
        }
      }

      assert {:ok, "first choice"} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when choices list is empty" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"choices" => []}
      }

      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when message content is nil" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "choices" => [%{"message" => %{"content" => nil}}]
        }
      }

      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "returns empty_response when body has no choices key" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"something" => "else"}
      }

      assert {:error, :empty_response} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request with body" do
      response = %HTTPower.Response{
        status: 400,
        headers: %{},
        body: %{"error" => %{"message" => "invalid model"}}
      }

      assert {:error, {:bad_request, %{"error" => _}}} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %HTTPower.Response{status: 401, headers: %{}, body: %{}}
      assert {:error, :unauthorized} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %HTTPower.Response{status: 429, headers: %{}, body: %{}}
      assert {:error, :rate_limited} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %HTTPower.Response{status: 500, headers: %{}, body: %{}}
      assert {:error, :server_error} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTP 503 to server_error" do
      response = %HTTPower.Response{status: 503, headers: %{}, body: %{}}
      assert {:error, :server_error} = OpenAI.parse_response({:ok, response})
    end

    test "maps other HTTP status codes to api_error" do
      response = %HTTPower.Response{status: 418, headers: %{}, body: %{"error" => "teapot"}}
      assert {:error, {:api_error, 418, _}} = OpenAI.parse_response({:ok, response})
    end

    test "maps HTTPower error to request_error" do
      error = %HTTPower.Error{reason: :timeout, message: "Request timeout"}
      assert {:error, {:request_error, :timeout}} = OpenAI.parse_response({:error, error})
    end
  end

  describe "infer/2" do
    setup do
      HTTPower.Test.setup()
    end

    test "full pipeline returns extracted text" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "hello"}, "finish_reason" => "stop"}]
        })
      end)

      assert {:ok, "hello"} = OpenAI.infer("Say hello.", api_key: "sk-test")
    end

    test "returns error on missing api key" do
      assert {:error, :missing_api_key} = OpenAI.infer("prompt")
    end
  end
end
