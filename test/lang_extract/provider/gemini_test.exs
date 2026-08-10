defmodule LangExtract.Provider.GeminiTest do
  # async: false - these tests exercise the env-var fallback by mutating
  # global API-key vars; running concurrently with any env-reading test
  # would be flaky by design.
  use ExUnit.Case, async: false

  alias LangExtract.Provider.Gemini
  alias LangExtract.Provider.Response

  # Payload assertions go through the real door: build a client, run
  # infer, and capture the request exactly as the server receives it.
  defp captured_request(prompt, opts) do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.request_path, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}
        ]
      })
    end)

    client =
      LangExtract.new(
        :gemini,
        [api_key: "gm-test", req_options: [plug: {Req.Test, __MODULE__}]] ++ opts
      )

    {:ok, _} = Gemini.infer(client, prompt)
    assert_receive {:request, path, json}
    {path, json}
  end

  describe "the inference request on the wire" do
    test "builds correct request with default opts" do
      # Pure: no api_key, no transport — the payload is data. The model
      # rides in the URL path, Gemini's addressing scheme.
      {url, body} = captured_request("Extract entities.", [])

      assert url == "/v1beta/models/gemini-3.5-flash:generateContent"
      assert body["contents"] == [%{"parts" => [%{"text" => "Extract entities."}]}]

      assert body["generationConfig"] == %{
               "temperature" => 0,
               "maxOutputTokens" => 4096,
               "responseMimeType" => "application/json"
             }
    end

    test "custom opts override defaults" do
      {url, body} =
        captured_request("prompt",
          model: "gemini-2.0-pro",
          max_tokens: 2048,
          temperature: 0.3
        )

      assert url =~ "gemini-2.0-pro"

      config = body["generationConfig"]
      assert config["maxOutputTokens"] == 2048
      assert config["temperature"] == 0.3
    end
  end

  describe "build_http_client/1" do
    setup do
      original = System.get_env("GEMINI_API_KEY")

      on_exit(fn ->
        if original,
          do: System.put_env("GEMINI_API_KEY", original),
          else: System.delete_env("GEMINI_API_KEY")
      end)

      :ok
    end

    test "builds the transport with defaults and auth" do
      assert {:ok, req} = Gemini.build_http_client(api_key: "test-key")

      assert req.options.base_url == "https://generativelanguage.googleapis.com"
      assert req.options.receive_timeout == 120_000
      assert req.options.retry == :transient
      # Key travels as Gemini's dedicated header, never in the URL
      assert req.headers["x-goog-api-key"] == ["test-key"]
      refute Map.has_key?(req.headers, "authorization")
      refute Map.has_key?(req.headers, "x-api-key")
    end

    test "api_key from opts takes precedence over env var" do
      System.put_env("GEMINI_API_KEY", "env-key")

      assert {:ok, req} = Gemini.build_http_client(api_key: "opts-key")

      assert req.headers["x-goog-api-key"] == ["opts-key"]
    end

    test "falls back to GEMINI_API_KEY env var" do
      System.put_env("GEMINI_API_KEY", "env-key")

      assert {:ok, req} = Gemini.build_http_client([])

      assert req.headers["x-goog-api-key"] == ["env-key"]
    end

    test "returns error when api key is missing" do
      System.delete_env("GEMINI_API_KEY")
      assert {:error, :missing_api_key} = Gemini.build_http_client([])
    end

    test "returns error when api key is empty string" do
      System.put_env("GEMINI_API_KEY", "")
      assert {:error, :missing_api_key} = Gemini.build_http_client([])
    end

    test "custom base_url is used" do
      assert {:ok, req} =
               Gemini.build_http_client(api_key: "test-key", base_url: "https://custom.api.com")

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

    # Gemini splits long completions across parts; standard clients
    # (including the Python SDK) concatenate every text part. Taking only
    # the first truncated the JSON payload mid-document, failing the chunk
    # as :invalid_format in a way that looked like a model problem.
    test "joins all text parts of a multi-part response" do
      response = %Req.Response{
        status: 200,
        body: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => ~s({"extractions")}, %{"text" => ~s(: []})}]
              },
              "finishReason" => "STOP"
            }
          ]
        }
      }

      assert {:ok, ~s({"extractions": []})} = Gemini.parse_response({:ok, response})
    end

    test "non-text parts are skipped when joining" do
      response = %Req.Response{
        status: 200,
        body: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{"functionCall" => %{"name" => "noop"}},
                  %{"text" => "payload"}
                ]
              },
              "finishReason" => "STOP"
            }
          ]
        }
      }

      assert {:ok, "payload"} = Gemini.parse_response({:ok, response})
    end

    # Thought summaries also carry "text"; joining them prepends prose to
    # the JSON and fails the chunk as invalid_format. Gemini only returns
    # them when includeThoughts is requested — still skip by flag.
    test "thought parts are skipped when joining text" do
      response = %Req.Response{
        status: 200,
        body: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{"text" => "thinking about it...", "thought" => true},
                  %{"text" => ~s({"extractions": []})}
                ]
              },
              "finishReason" => "STOP"
            }
          ]
        }
      }

      assert {:ok, ~s({"extractions": []})} = Gemini.parse_response({:ok, response})
    end

    # MAX_TOKENS mid-thought: every part is a thought summary and no
    # answer text exists — an empty reply, not an invalid one.
    test "returns empty_response when all parts are thoughts" do
      response = %Req.Response{
        status: 200,
        body: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "thinking about it...", "thought" => true}]
              },
              "finishReason" => "MAX_TOKENS"
            }
          ]
        }
      }

      assert {:error, :empty_response} = Gemini.parse_response({:ok, response})
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
      assert {:error, {:rate_limited, nil}} = Gemini.parse_response({:ok, response})
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

  # Gemini-specific wire property, not executor plumbing: the API key
  # must reach the server as the x-goog-api-key header and never as a
  # query parameter (where it would land in server/proxy access logs).
  describe "key placement on the wire" do
    test "the key travels as a header, never in the URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["gm-test"]
        assert conn.query_string == ""

        Req.Test.json(conn, %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "hello"}]},
              "finishReason" => "STOP"
            }
          ]
        })
      end)

      client =
        LangExtract.new(:gemini,
          api_key: "gm-test",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert {:ok, %Response{text: "hello"}} = Gemini.infer(client, "Say hello.")
    end
  end
end
