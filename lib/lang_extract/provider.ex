defmodule LangExtract.Provider do
  @moduledoc """
  Behaviour for LLM inference providers.

  Each provider implements `infer/2` which takes a prompt string and returns
  a `LangExtract.Provider.Response` — the raw response text plus token usage
  when the API reported it. Parsing and normalization are the caller's
  responsibility.

  Shared helpers for API key resolution and HTTP error mapping are provided
  for use by provider implementations.

  Providers speak `Req`: `c:build_http_client/1` must return a
  `Req.Request.t()`, and the shared helpers assume Req's request and
  response shapes. Third-party implementations must build on Req (or wrap
  their transport in it) — no transport adapter layer is planned.
  """

  alias LangExtract.Provider.Response

  @typedoc """
  Every error a provider can return from `c:infer/2`.

  The runner's retry policy dispatches on these shapes: `:rate_limited`
  pauses globally, `:server_error` and `:request_error` consume retry
  budget, everything else fails the chunk immediately.
  """
  @type error ::
          :missing_api_key
          | :empty_response
          | :unauthorized
          | :server_error
          | {:bad_request, term()}
          | {:rate_limited, non_neg_integer() | nil}
          | {:api_error, pos_integer(), term()}
          | {:request_error, Exception.t()}

  @callback build_http_client(opts :: keyword()) :: {:ok, Req.Request.t()} | {:error, term()}

  @callback infer(prompt :: String.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, error()}

  @doc """
  Resolves an API key from opts or an environment variable.

  Returns `{:ok, key}` or `{:error, :missing_api_key}` if nil or empty.
  For use by provider implementations.
  """
  @spec fetch_api_key(keyword(), String.t()) :: {:ok, String.t()} | {:error, :missing_api_key}
  def fetch_api_key(opts, env_var) do
    api_key = Keyword.get(opts, :api_key) || System.get_env(env_var)

    if api_key in [nil, ""] do
      {:error, :missing_api_key}
    else
      {:ok, api_key}
    end
  end

  @doc """
  Extracts common provider options (model, max_tokens, temperature, base_url)
  from opts with provider-specific defaults. For use by provider implementations.
  """
  @spec common_opts(keyword(), keyword()) :: %{
          model: String.t(),
          max_tokens: pos_integer(),
          temperature: number() | nil,
          base_url: String.t()
        }
  def common_opts(opts, defaults) do
    %{
      model: Keyword.get(opts, :model, defaults[:model]),
      max_tokens: Keyword.get(opts, :max_tokens, defaults[:max_tokens]),
      temperature: Keyword.get(opts, :temperature, defaults[:temperature]),
      base_url: Keyword.get(opts, :base_url, defaults[:base_url])
    }
  end

  @doc """
  Returns a pre-built HTTP client from opts, or builds one via the given function.
  """
  @spec resolve_http_client(keyword(), (keyword() -> {:ok, Req.Request.t()} | {:error, term()})) ::
          {:ok, Req.Request.t()} | {:error, term()}
  def resolve_http_client(opts, build_fn) do
    case Keyword.get(opts, :http_client) do
      %Req.Request{} = req -> {:ok, req}
      _ -> build_fn.(opts)
    end
  end

  # LLM completions routinely exceed Req's 15s receive_timeout default, and
  # transient failures (429/5xx/transport) would otherwise permanently drop
  # a chunk since the orchestrator doesn't retry.
  #
  # redirect: false — Req strips only the standard authorization header on
  # cross-host redirects; custom auth headers (Claude's x-api-key, Gemini's
  # x-goog-api-key) would be forwarded to the redirect target. LLM APIs
  # never legitimately redirect
  # these POSTs, so a 3xx surfaces as {:api_error, 3xx, body} instead.
  # Callers who genuinely need redirects can re-enable via :req_options.
  @http_defaults [
    receive_timeout: 120_000,
    retry: :transient,
    redirect: false
  ]

  @doc """
  Merges caller-supplied `:req_options` into the provider's Req options.

  Applies shared HTTP defaults first (120s receive timeout, transient
  retries), then the provider's own options, then anything in `:req_options`
  — so callers can override any Req configuration (timeouts, retry policy,
  pool settings, plug for testing, etc.) without the provider needing to
  know about them.
  """
  @spec req_options(keyword(), keyword()) :: keyword()
  def req_options(opts, req_opts) do
    @http_defaults
    |> Keyword.merge(req_opts)
    |> Keyword.merge(Keyword.get(opts, :req_options) || [])
  end

  @doc """
  Posts the request and parses the response inside a
  `[:lang_extract, :request]` telemetry span (`:start`, `:stop`, and
  `:exception` events).

  The span's `duration` wraps the full `Req.post/2` call — including Req's
  transient retries — because that is the latency the pipeline experiences.
  `:stop` measurements additionally carry `input_tokens`/`output_tokens`
  when the response body has a usage block (Anthropic/OpenAI `"usage"`,
  Gemini `"usageMetadata"`); handlers should treat missing keys as unknown,
  not zero.

  Metadata: the caller's `provider` and `model`; `:stop` adds `status` —
  the HTTP status code, or `:transport_error` when no response arrived.
  """
  @spec request(Req.Request.t(), keyword(), map(), (term() ->
                                                      {:ok, String.t()} | {:error, error()})) ::
          {:ok, Response.t()} | {:error, error()}
  def request(req, request_opts, metadata, parse_response) do
    :telemetry.span([:lang_extract, :request], metadata, fn ->
      raw = Req.post(req, request_opts)
      usage = usage_measurements(raw)

      {
        wrap_response(parse_response.(raw), usage),
        usage,
        Map.put(metadata, :status, response_status(raw))
      }
    end)
  end

  # Usage rides the success value as well as the telemetry measurements:
  # the same keys, nil instead of empty when the API reported nothing.
  defp wrap_response({:ok, text}, usage) when map_size(usage) == 0 do
    {:ok, %Response{text: text, usage: nil}}
  end

  defp wrap_response({:ok, text}, usage), do: {:ok, %Response{text: text, usage: usage}}
  defp wrap_response({:error, _} = error, _usage), do: error

  defp response_status({:ok, %Req.Response{status: status}}), do: status
  defp response_status({:error, _exception}), do: :transport_error

  defp usage_measurements({:ok, %Req.Response{body: %{"usage" => usage}}}) do
    token_pair(
      usage["input_tokens"] || usage["prompt_tokens"],
      usage["output_tokens"] || usage["completion_tokens"]
    )
  end

  defp usage_measurements({:ok, %Req.Response{body: %{"usageMetadata" => usage}}}) do
    token_pair(usage["promptTokenCount"], usage["candidatesTokenCount"])
  end

  defp usage_measurements(_raw), do: %{}

  defp token_pair(input, output) when is_integer(input) and is_integer(output) do
    %{input_tokens: input, output_tokens: output}
  end

  defp token_pair(_input, _output), do: %{}

  @doc """
  Maps a Req response to a provider result tuple.

  Delegates to `extract_text` for HTTP 200; maps error status codes and
  network failures to standard error tuples. For use by provider implementations.
  """
  @spec map_response(
          {:ok, Req.Response.t()} | {:error, Exception.t()},
          (term() -> {:ok, String.t()} | {:error, :empty_response})
        ) :: {:ok, String.t()} | {:error, error()}
  def map_response({:ok, %Req.Response{status: 200, body: body}}, extract_text) do
    extract_text.(body)
  end

  def map_response({:ok, %Req.Response{status: 400, body: body}}, _) do
    {:error, {:bad_request, body}}
  end

  def map_response({:ok, %Req.Response{status: 401}}, _) do
    {:error, :unauthorized}
  end

  # retry-after is enriched at the source: the runner's global backoff
  # needs the server's deadline, and it only exists on this response.
  def map_response({:ok, %Req.Response{status: 429} = response}, _) do
    {:error, {:rate_limited, retry_after_ms(response)}}
  end

  def map_response({:ok, %Req.Response{status: status}}, _) when status >= 500 do
    {:error, :server_error}
  end

  def map_response({:ok, %Req.Response{status: status, body: body}}, _) do
    {:error, {:api_error, status, body}}
  end

  def map_response({:error, exception}, _) do
    {:error, {:request_error, exception}}
  end

  defp retry_after_ms(response) do
    case Req.Response.get_header(response, "retry-after") do
      [seconds | _] ->
        case Integer.parse(seconds) do
          {s, ""} -> s * 1000
          _ -> nil
        end

      [] ->
        nil
    end
  end
end
