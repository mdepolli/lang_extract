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
      assert {:ok, {req, request_opts}} =
               OpenAI.build_request("Extract entities.", api_key: "sk-test")

      assert request_opts[:url] == "/v1/chat/completions"
      assert req.options.base_url == "https://api.openai.com"
      assert req.headers["authorization"] == ["Bearer sk-test"]

      body = request_opts[:json]
      assert body["model"] == "gpt-4o-mini"
      assert body["max_tokens"] == 4096
      assert body["temperature"] == 0
      assert body["response_format"] == %{"type" => "json_object"}

      [system_msg, user_msg] = body["messages"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "Respond with JSON."
      assert user_msg == %{"role" => "user", "content" => "Extract entities."}
    end

    test "json_mode false omits response_format and system message" do
      assert {:ok, {_req, request_opts}} =
               OpenAI.build_request("Tell me a story.", api_key: "sk-test", json_mode: false)

      body = request_opts[:json]
      refute Map.has_key?(body, "response_format")
      assert body["messages"] == [%{"role" => "user", "content" => "Tell me a story."}]
    end

    test "custom model, max_tokens, and temperature override defaults" do
      assert {:ok, {_req, request_opts}} =
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

      assert {:ok, {req, _request_opts}} =
               OpenAI.build_request("prompt", api_key: "sk-opts")

      assert req.headers["authorization"] == ["Bearer sk-opts"]
    end

    test "falls back to OPENAI_API_KEY env var" do
      System.put_env("OPENAI_API_KEY", "sk-env")
      assert {:ok, {req, _request_opts}} = OpenAI.build_request("prompt", [])
      assert req.headers["authorization"] == ["Bearer sk-env"]
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
      assert {:ok, {req, _request_opts}} =
               OpenAI.build_request("prompt",
                 api_key: "sk-test",
                 base_url: "http://localhost:11434"
               )

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
      assert {:error, :rate_limited} = OpenAI.parse_response({:ok, response})
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

  describe "infer/2" do
    setup do
      original = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("OPENAI_API_KEY", original),
          else: System.delete_env("OPENAI_API_KEY")
      end)

      :ok
    end

    test "full pipeline returns extracted text" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "hello"}, "finish_reason" => "stop"}]
        })
      end)

      assert {:ok, "hello"} =
               OpenAI.infer("Say hello.",
                 api_key: "sk-test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "returns error on missing api key" do
      System.delete_env("OPENAI_API_KEY")
      assert {:error, :missing_api_key} = OpenAI.infer("prompt")
    end
  end
end
