defmodule LangExtract.ProviderTest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider.{Claude, Gemini, OpenAI}

  describe "[:lang_extract, :request] telemetry span" do
    # Telemetry handlers are global: concurrent async tests calling infer
    # emit events too. Each test uses a unique model name and matches
    # events on it, so foreign events are ignored, not misasserted.
    setup do
      handler_id = "request-telemetry-#{inspect(self())}"
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [[:lang_extract, :request, :start], [:lang_extract, :request, :stop]],
        fn [:lang_extract, :request, phase], measurements, metadata, _config ->
          send(parent, {phase, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{model: "test-model-#{System.unique_integer([:positive])}"}
    end

    defp req_options, do: [plug: {Req.Test, __MODULE__}]

    test "Anthropic usage shape: start + stop, tokens, status, provider", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "hi"}],
          "usage" => %{"input_tokens" => 120, "output_tokens" => 45}
        })
      end)

      assert {:ok, "hi"} =
               Claude.infer("prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: req_options()
               )

      assert_receive {:start, start_measurements, %{model: ^model, provider: :claude}}
      assert is_integer(start_measurements.system_time)

      assert_receive {:stop, measurements, %{model: ^model} = metadata}
      assert measurements.input_tokens == 120
      assert measurements.output_tokens == 45
      assert is_integer(measurements.duration) and measurements.duration > 0
      assert metadata.provider == :claude
      assert metadata.status == 200
    end

    test "OpenAI usage shape maps prompt/completion tokens", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "hi"}}],
          "usage" => %{"prompt_tokens" => 80, "completion_tokens" => 22}
        })
      end)

      assert {:ok, "hi"} =
               OpenAI.infer("prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: req_options()
               )

      assert_receive {:stop, measurements, %{model: ^model, provider: :openai}}
      assert measurements.input_tokens == 80
      assert measurements.output_tokens == 22
    end

    test "Gemini usageMetadata shape maps prompt/candidates token counts", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => "hi"}]}, "finishReason" => "STOP"}
          ],
          "usageMetadata" => %{"promptTokenCount" => 64, "candidatesTokenCount" => 18}
        })
      end)

      assert {:ok, "hi"} =
               Gemini.infer("prompt",
                 api_key: "gm-test",
                 model: model,
                 req_options: req_options()
               )

      assert_receive {:stop, measurements, %{model: ^model, provider: :gemini}}
      assert measurements.input_tokens == 64
      assert measurements.output_tokens == 18
    end

    test "error responses emit stop with status and no token keys", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, Jason.encode!(%{}))
      end)

      assert {:error, :rate_limited} =
               Claude.infer("prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )

      assert_receive {:stop, measurements, %{model: ^model} = metadata}
      assert metadata.status == 429
      refute Map.has_key?(measurements, :input_tokens)
      refute Map.has_key?(measurements, :output_tokens)
    end

    test "transport errors emit stop with :transport_error status", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, {:request_error, _}} =
               Claude.infer("prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )

      assert_receive {:stop, measurements, %{model: ^model} = metadata}
      assert metadata.status == :transport_error
      assert is_integer(measurements.duration)
    end

    test "a response without a usage block omits token measurements", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "hi"}]})
      end)

      assert {:ok, "hi"} =
               Claude.infer("prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: req_options()
               )

      assert_receive {:stop, measurements, %{model: ^model}}
      refute Map.has_key?(measurements, :input_tokens)
    end
  end
end
