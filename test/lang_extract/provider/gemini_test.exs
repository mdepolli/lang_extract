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

    test "custom base_url is used" do
      assert {:ok, {client, _path, _request_opts}} =
               Gemini.build_request("prompt",
                 api_key: "test-key",
                 base_url: "https://proxy.example.com"
               )

      assert client.base_url == "https://proxy.example.com"
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
