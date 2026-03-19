defmodule LangExtract.Provider.GeminiTest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.Gemini

  describe "build_request/2" do
    setup do
      original = System.get_env("GEMINI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("GEMINI_API_KEY", original),
          else: System.delete_env("GEMINI_API_KEY")
      end)

      :ok
    end

    test "builds correct request with default opts" do
      assert {:ok, {req, request_opts}} =
               Gemini.build_request("Extract entities.", api_key: "test-key")

      assert request_opts[:url] == "/v1beta/models/gemini-2.0-flash:generateContent?key=test-key"
      assert req.options.base_url == "https://generativelanguage.googleapis.com"
      # No auth header — key is in query param
      refute Map.has_key?(req.headers, "authorization")
      refute Map.has_key?(req.headers, "x-api-key")

      body = request_opts[:json]
      assert body["contents"] == [%{"parts" => [%{"text" => "Extract entities."}]}]

      assert body["generationConfig"] == %{
               "temperature" => 0,
               "maxOutputTokens" => 4096,
               "responseMimeType" => "application/json"
             }
    end

    test "custom opts override defaults" do
      assert {:ok, {_req, request_opts}} =
               Gemini.build_request("prompt",
                 api_key: "test-key",
                 model: "gemini-2.0-pro",
                 max_tokens: 2048,
                 temperature: 0.3
               )

      assert request_opts[:url] =~ "gemini-2.0-pro"

      body = request_opts[:json]
      config = body["generationConfig"]
      assert config["maxOutputTokens"] == 2048
      assert config["temperature"] == 0.3
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("GEMINI_API_KEY", "env-key")

      assert {:ok, {_req, request_opts}} =
               Gemini.build_request("prompt", api_key: "opts-key")

      assert request_opts[:url] =~ "key=opts-key"
    end

    test "falls back to GEMINI_API_KEY env var" do
      System.put_env("GEMINI_API_KEY", "env-key")

      assert {:ok, {_req, request_opts}} = Gemini.build_request("prompt", [])

      assert request_opts[:url] =~ "key=env-key"
    end

    test "returns error when api key is missing" do
      System.delete_env("GEMINI_API_KEY")
      assert {:error, :missing_api_key} = Gemini.build_request("prompt", [])
    end

    test "returns error when api key is empty string" do
      System.put_env("GEMINI_API_KEY", "")
      assert {:error, :missing_api_key} = Gemini.build_request("prompt", [])
    end

    test "custom base_url is used" do
      assert {:ok, {req, _request_opts}} =
               Gemini.build_request("prompt",
                 api_key: "test-key",
                 base_url: "https://custom.api.com"
               )

      assert req.options.base_url == "https://custom.api.com"
    end
  end

  describe "parse_response/1" do
    test "extracts text from successful response" do
      response = %Req.Response{
        status: 200,
        body: %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "extracted data"}]},
              "finishReason" => "STOP"
            }
          ]
        }
      }

      assert {:ok, "extracted data"} = Gemini.parse_response({:ok, response})
    end

    test "extracts first text part from multiple parts" do
      response = %Req.Response{
        status: 200,
        body: %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "first"}, %{"text" => "second"}]},
              "finishReason" => "STOP"
            }
          ]
        }
      }

      assert {:ok, "first"} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when candidates is empty" do
      response = %Req.Response{status: 200, body: %{"candidates" => []}}
      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when candidate has no content key (safety blocked)" do
      response = %Req.Response{
        status: 200,
        body: %{"candidates" => [%{"finishReason" => "SAFETY"}]}
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when parts is empty" do
      response = %Req.Response{
        status: 200,
        body: %{"candidates" => [%{"content" => %{"parts" => []}}]}
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when body has no candidates" do
      response = %Req.Response{status: 200, body: %{}}
      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request" do
      response = %Req.Response{status: 400, body: %{"error" => "bad"}}
      assert {:error, {:bad_request, _}} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %Req.Response{status: 401, body: %{}}
      assert {:error, :unauthorized} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %Req.Response{status: 429, body: %{}}
      assert {:error, :rate_limited} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %Req.Response{status: 500, body: %{}}
      assert {:error, :server_error} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 503 to server_error" do
      response = %Req.Response{status: 503, body: %{}}
      assert {:error, :server_error} = Gemini.parse_response({:ok, response})
    end

    test "maps other HTTP status codes to api_error" do
      response = %Req.Response{status: 418, body: %{"error" => "teapot"}}
      assert {:error, {:api_error, 418, _}} = Gemini.parse_response({:ok, response})
    end

    test "maps transport error to request_error" do
      error = %Mint.TransportError{reason: :timeout}

      assert {:error, {:request_error, %Mint.TransportError{}}} =
               Gemini.parse_response({:error, error})
    end
  end

  describe "infer/2" do
    test "full pipeline returns extracted text" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "hello"}]},
              "finishReason" => "STOP"
            }
          ]
        })
      end)

      assert {:ok, "hello"} =
               Gemini.infer("Say hello.", api_key: "gm-test", plug: {Req.Test, __MODULE__})
    end

    test "returns error on missing api key" do
      assert {:error, :missing_api_key} = Gemini.infer("prompt")
    end
  end
end
