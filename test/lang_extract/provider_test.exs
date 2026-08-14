defmodule LangExtract.ProviderTest do
  use ExUnit.Case, async: true

  alias LangExtract.Provider
  alias LangExtract.Provider.Response

  describe "req_options/2" do
    # Headers are resolved before the keyword merge: normalize map/list
    # shapes, Map.merge per-key, then attach once. A caller adding one
    # custom header must not wipe the provider's auth — every chunk would
    # 401, and 4xx is never retried.

    @provider_map [
      headers: %{"x-api-key" => "sk-test", "anthropic-version" => "2023-06-01"}
    ]

    test "map user headers merge per-key with map provider headers" do
      opts = [req_options: [headers: %{"x-custom" => "1", "anthropic-version" => "override"}]]

      assert Provider.req_options(opts, @provider_map)[:headers] == %{
               "x-api-key" => "sk-test",
               "anthropic-version" => "override",
               "x-custom" => "1"
             }
    end

    test "list-tuple user headers merge per-key with map provider headers" do
      opts = [req_options: [headers: [{"x-custom", "1"}]]]

      assert Provider.req_options(opts, @provider_map)[:headers] == %{
               "x-api-key" => "sk-test",
               "anthropic-version" => "2023-06-01",
               "x-custom" => "1"
             }
    end

    test "keyword-list user headers merge per-key with map provider headers" do
      provider = [headers: %{"authorization" => "Bearer sk-test"}]
      opts = [req_options: [headers: ["x-custom": "1"]]]

      assert Provider.req_options(opts, provider)[:headers] == %{
               "authorization" => "Bearer sk-test",
               "x-custom" => "1"
             }
    end

    test "list provider headers merge per-key with map user headers" do
      provider = [headers: [{"authorization", "Bearer sk"}, {"x-provider", "1"}]]
      opts = [req_options: [headers: %{"x-custom" => "1", "x-provider" => "override"}]]

      assert Provider.req_options(opts, provider)[:headers] == %{
               "authorization" => "Bearer sk",
               "x-provider" => "override",
               "x-custom" => "1"
             }
    end

    test "list provider headers merge per-key with list user headers" do
      provider = [headers: [{"x-api-key", "sk-test"}]]
      opts = [req_options: [headers: [{"x-custom", "1"}]]]

      assert Provider.req_options(opts, provider)[:headers] == %{
               "x-api-key" => "sk-test",
               "x-custom" => "1"
             }
    end

    test "provider headers alone are kept when the user omits headers" do
      assert Provider.req_options([], @provider_map)[:headers] == %{
               "x-api-key" => "sk-test",
               "anthropic-version" => "2023-06-01"
             }
    end

    test "list-shaped provider headers alone are normalized to a map" do
      provider = [headers: [{"authorization", "Bearer sk"}]]

      assert Provider.req_options([], provider)[:headers] == %{
               "authorization" => "Bearer sk"
             }
    end

    test "user headers alone are kept when the provider omits headers" do
      opts = [req_options: [headers: %{"x-custom" => "1"}]]

      assert Provider.req_options(opts, [])[:headers] == %{"x-custom" => "1"}
    end

    test "list-shaped user headers alone are normalized to a map" do
      opts = [req_options: [headers: [{"x-custom", "1"}]]]

      assert Provider.req_options(opts, [])[:headers] == %{"x-custom" => "1"}
    end

    test "neither side supplying headers leaves :headers unset" do
      refute Keyword.has_key?(Provider.req_options([], []), :headers)
    end

    test "header merge does not disturb other keyword overrides" do
      provider = [headers: %{"x-api-key" => "sk"}, receive_timeout: 30_000]
      opts = [req_options: [headers: [{"x-custom", "1"}], receive_timeout: 5_000, retry: false]]

      merged = Provider.req_options(opts, provider)

      assert merged[:headers] == %{"x-api-key" => "sk", "x-custom" => "1"}
      assert merged[:receive_timeout] == 5_000
      assert merged[:retry] == false
    end

    test "empty list headers from the user still keep provider auth" do
      opts = [req_options: [headers: []]]

      assert Provider.req_options(opts, @provider_map)[:headers] == %{
               "x-api-key" => "sk-test",
               "anthropic-version" => "2023-06-01"
             }
    end

    # Req translates atom underscores to dashes (headers: [user_agent: _]
    # is the shape its own docs use); resolving headers before Req sees
    # them must not change the wire name.
    test "atom header names normalize like Req: underscores to dashes, downcased" do
      opts = [req_options: [headers: [user_agent: "mine"]]]

      assert Provider.req_options(opts, @provider_map)[:headers] == %{
               "x-api-key" => "sk-test",
               "anthropic-version" => "2023-06-01",
               "user-agent" => "mine"
             }
    end

    # Without downcasing, Map.merge keeps both casings and Req then
    # concatenates the values — broken auth, the exact class this merge
    # exists to prevent.
    test "mixed-case user header names override the provider's lowercase key" do
      provider = [headers: %{"authorization" => "Bearer PROVIDER"}]
      opts = [req_options: [headers: %{"Authorization" => "Bearer USER"}]]

      assert Provider.req_options(opts, provider)[:headers] == %{
               "authorization" => "Bearer USER"
             }
    end

    test "duplicate names in list headers concatenate values like Req" do
      opts = [req_options: [headers: [{"accept", "a"}, {"accept", "b"}]]]

      assert Provider.req_options(opts, [])[:headers] == %{"accept" => ["a", "b"]}
    end

    test "non-map non-list headers raise instead of silently vanishing" do
      opts = [req_options: [headers: "garbage"]]

      assert_raise ArgumentError, ~r/headers must be a map or a list/, fn ->
        Provider.req_options(opts, @provider_map)
      end
    end
  end

  # All executor tests drive a real client through the provider
  # callback: build the client once, run one inference over it.
  defp infer(provider, prompt, opts) do
    client = LangExtract.new(provider, opts)
    client.provider.infer(client, prompt)
  end

  describe "provider infer/2 dispatch" do
    test "builds the provider request and executes it over the client transport" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "extracted entities"}]
        })
      end)

      assert {:ok, %Response{text: "extracted entities"}} =
               infer(:claude, "Extract entities.",
                 api_key: "sk-test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    # 2 MiB library cap on binary bodies (JSON is already a map by the
    # time Req returns it). A flood of plain text must fail the chunk
    # without being passed to the provider parser.
    test "rejects an oversize binary response body" do
      oversize = String.duplicate("x", 2 * 1024 * 1024 + 1)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, oversize)
      end)

      assert {:error, {:api_error, 413, message}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert message =~ "response body exceeds"
    end
  end

  describe "error body bounds" do
    # Req decodes JSON content-types before map_response sees the body, so
    # the 2 MiB binary transport cap never fires on this path — an
    # unbounded decoded map would otherwise ride the reason term into
    # Result.errors and serialized files for the life of the run.
    test "decoded JSON error bodies flatten to a bounded preview string" do
      huge = Jason.encode!(%{"error" => %{"message" => String.duplicate("x", 500_000)}})

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, huge)
      end)

      assert {:error, {:bad_request, preview}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )

      assert is_binary(preview)
      assert byte_size(preview) < 8_192
    end

    test "unexpected-status bodies flatten the same way, keeping the content" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(418, Jason.encode!(%{"error" => "teapot"}))
      end)

      assert {:error, {:api_error, 418, preview}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )

      assert is_binary(preview)
      assert preview =~ "teapot"
    end
  end

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
        &__MODULE__.forward_event/4,
        parent
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{model: "test-model-#{System.unique_integer([:positive])}"}
    end

    # Module-qualified capture, not an anonymous fn, so telemetry stores it
    # without the local-handler penalty; the parent pid travels as config.
    def forward_event([:lang_extract, :request, phase], measurements, metadata, parent) do
      send(parent, {phase, measurements, metadata})
    end

    defp req_options, do: [plug: {Req.Test, __MODULE__}]

    test "Anthropic usage shape: start + stop, tokens, status, provider", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "hi"}],
          "usage" => %{"input_tokens" => 120, "output_tokens" => 45}
        })
      end)

      assert {:ok, %Response{text: "hi"}} =
               infer(:claude, "prompt",
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

      assert {:ok, %Response{text: "hi"}} =
               infer(:openai, "prompt",
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

      assert {:ok, %Response{text: "hi"}} =
               infer(:gemini, "prompt",
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

      assert {:error, {:rate_limited, nil}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )

      assert_receive {:stop, measurements, %{model: ^model} = metadata}
      assert metadata.status == 429
      refute Map.has_key?(measurements, :input_tokens)
      refute Map.has_key?(measurements, :output_tokens)
    end

    test "429 with retry-after carries the deadline in milliseconds", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, "{}")
      end)

      assert {:error, {:rate_limited, 7000}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )
    end

    # A negative retry-after is malformed per RFC 9110 (delay-seconds is
    # non-negative) and would violate the {:rate_limited, non_neg_integer()}
    # error type — treated like any other unparseable value.
    test "a negative retry-after parses as nil", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "-7")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, "{}")
      end)

      assert {:error, {:rate_limited, nil}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )
    end

    test "transport errors emit stop with :transport_error status", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, {:request_error, _}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )

      assert_receive {:stop, measurements, %{model: ^model} = metadata}
      assert metadata.status == :transport_error
      assert is_integer(measurements.duration)
    end

    test "redirects are not followed: 3xx surfaces as api_error", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.example.com/v1/messages")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, {:api_error, 302, _body}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: req_options()
               )

      assert_receive {:stop, _measurements, %{model: ^model, status: 302}}
    end

    test "a response without a usage block omits token measurements", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "hi"}]})
      end)

      assert {:ok, %Response{text: "hi"}} =
               infer(:claude, "prompt",
                 api_key: "sk-test",
                 model: model,
                 req_options: req_options()
               )

      assert_receive {:stop, measurements, %{model: ^model}}
      refute Map.has_key?(measurements, :input_tokens)
    end
  end
end
