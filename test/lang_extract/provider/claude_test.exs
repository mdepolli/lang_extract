defmodule LangExtract.Provider.ClaudeTest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.Claude

  describe "build_request/2" do
    test "builds correct request with default opts" do
      assert {:ok, {client, path, request_opts}} =
               Claude.build_request("Extract entities.", api_key: "sk-test")

      assert path == "/v1/messages"
      assert client.base_url == "https://api.anthropic.com"

      body = Jason.decode!(request_opts[:body])
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

      body = Jason.decode!(request_opts[:body])
      assert body["model"] == "claude-opus-4-20250514"
      assert body["max_tokens"] == 1024
      assert body["temperature"] == 0.5
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt", api_key: "sk-opts")

      assert client.options[:headers]["x-api-key"] == "sk-opts"

      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "falls back to ANTHROPIC_API_KEY env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, {client, _path, _request_opts}} =
               Claude.build_request("prompt", [])

      assert client.options[:headers]["x-api-key"] == "sk-env"

      System.delete_env("ANTHROPIC_API_KEY")
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
end
