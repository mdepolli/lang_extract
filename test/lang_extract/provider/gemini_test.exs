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
      assert {:ok, {client, path, request_opts}} =
               Gemini.build_request("Extract entities.", api_key: "test-key")

      assert path == "/v1beta/models/gemini-2.0-flash:generateContent?key=test-key"
      assert client.base_url == "https://generativelanguage.googleapis.com"
      assert client.options[:headers]["content-type"] == "application/json"
      refute Map.has_key?(client.options[:headers], "authorization")

      body = Jason.decode!(request_opts[:body])
      assert body["contents"] == [%{"parts" => [%{"text" => "Extract entities."}]}]

      assert body["generationConfig"] == %{
               "temperature" => 0,
               "maxOutputTokens" => 4096,
               "responseMimeType" => "application/json"
             }
    end

    test "custom model, max_tokens, and temperature override defaults" do
      assert {:ok, {_client, path, request_opts}} =
               Gemini.build_request("prompt",
                 api_key: "test-key",
                 model: "gemini-1.5-pro",
                 max_tokens: 1024,
                 temperature: 0.7
               )

      assert path == "/v1beta/models/gemini-1.5-pro:generateContent?key=test-key"

      body = Jason.decode!(request_opts[:body])
      assert body["generationConfig"]["maxOutputTokens"] == 1024
      assert body["generationConfig"]["temperature"] == 0.7
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("GEMINI_API_KEY", "env-key")

      assert {:ok, {_client, path, _request_opts}} =
               Gemini.build_request("prompt", api_key: "opts-key")

      assert path =~ "key=opts-key"
      refute path =~ "key=env-key"
    end

    test "falls back to GEMINI_API_KEY env var" do
      System.put_env("GEMINI_API_KEY", "env-key")

      assert {:ok, {_client, path, _request_opts}} =
               Gemini.build_request("prompt", [])

      assert path =~ "key=env-key"
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
      assert {:ok, {client, _path, _request_opts}} =
               Gemini.build_request("prompt",
                 api_key: "test-key",
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
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "extracted entities here"}]
              }
            }
          ]
        }
      }

      assert {:ok, "extracted entities here"} = Gemini.parse_response({:ok, response})
    end

    test "extracts text from first part when multiple parts present" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{"text" => "first part"},
                  %{"text" => "second part"}
                ]
              }
            }
          ]
        }
      }

      assert {:ok, "first part"} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when candidates list is empty" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"candidates" => []}
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when candidate has no content key (safety blocked)" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "candidates" => [
            %{"finishReason" => "SAFETY"}
          ]
        }
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when parts list is empty" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{
          "candidates" => [
            %{"content" => %{"parts" => []}}
          ]
        }
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "returns empty_response when body has no candidates key" do
      response = %HTTPower.Response{
        status: 200,
        headers: %{},
        body: %{"something" => "else"}
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 400 to bad_request with body" do
      response = %HTTPower.Response{
        status: 400,
        headers: %{},
        body: %{"error" => %{"message" => "invalid model"}}
      }

      assert {:error, {:bad_request, %{"error" => _}}} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 401 to unauthorized" do
      response = %HTTPower.Response{status: 401, headers: %{}, body: %{}}
      assert {:error, :unauthorized} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 429 to rate_limited" do
      response = %HTTPower.Response{status: 429, headers: %{}, body: %{}}
      assert {:error, :rate_limited} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 500 to server_error" do
      response = %HTTPower.Response{status: 500, headers: %{}, body: %{}}
      assert {:error, :server_error} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTP 503 to server_error" do
      response = %HTTPower.Response{status: 503, headers: %{}, body: %{}}
      assert {:error, :server_error} = Gemini.parse_response({:ok, response})
    end

    test "maps other HTTP status codes to api_error" do
      response = %HTTPower.Response{status: 418, headers: %{}, body: %{"error" => "teapot"}}
      assert {:error, {:api_error, 418, _}} = Gemini.parse_response({:ok, response})
    end

    test "maps HTTPower error to request_error" do
      error = %HTTPower.Error{reason: :timeout, message: "Request timeout"}
      assert {:error, {:request_error, :timeout}} = Gemini.parse_response({:error, error})
    end
  end

  describe "infer/2 integration" do
    @tag :external
    test "makes a real API call and returns a string response" do
      api_key = System.get_env("GEMINI_API_KEY")

      if is_nil(api_key) do
        IO.puts("Skipping: GEMINI_API_KEY not set")
      else
        assert {:ok, response} = Gemini.infer("Respond with exactly: hello", api_key: api_key)
        assert is_binary(response)
        assert String.length(response) > 0
      end
    end
  end
end
