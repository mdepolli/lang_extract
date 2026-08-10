defmodule LangExtract.ClientTest do
  use ExUnit.Case, async: true

  describe "provider registry" do
    test "every provider atom resolves to its module" do
      for {atom, module} <- [
            claude: LangExtract.Provider.Claude,
            openai: LangExtract.Provider.OpenAI,
            gemini: LangExtract.Provider.Gemini,
            grok: LangExtract.Provider.Grok
          ] do
        client = LangExtract.new(atom, api_key: "test-key")
        assert client.provider == module
      end
    end
  end

  describe "Inspect redaction" do
    test "inspect output never contains the API key" do
      client = LangExtract.new(:claude, api_key: "sk-ant-supersecret-123")

      rendered = inspect(client)

      refute rendered =~ "sk-ant-supersecret-123"
      refute rendered =~ "supersecret"
    end

    test "options and http_client are excluded entirely" do
      client =
        LangExtract.new(:claude,
          api_key: "sk-ant-supersecret-123",
          base_url: "https://internal.example.com"
        )

      rendered = inspect(client)

      refute rendered =~ "options"
      refute rendered =~ "http_client"
      # base_url lives in options; headers/config live in http_client
      refute rendered =~ "internal.example.com"
    end

    test "provider stays visible for debuggability" do
      client = LangExtract.new(:claude, api_key: "sk-ant-supersecret-123")

      assert inspect(client) =~ "Provider.Claude"
    end

    # structs: false is deliberately absent: it bypasses every derived
    # Inspect implementation in Elixir (ours, Req's header redaction, all of
    # them), so surviving it is not a contract struct-based redaction can make.
    test "redaction holds under inspect options used by loggers" do
      client = LangExtract.new(:claude, api_key: "sk-ant-supersecret-123")

      for opts <- [[limit: :infinity], [printable_limit: :infinity], [width: :infinity]] do
        refute inspect(client, opts) =~ "supersecret"
      end
    end
  end
end
