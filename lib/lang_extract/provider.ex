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
          | {:bad_request, String.t()}
          | {:rate_limited, non_neg_integer() | nil}
          | {:api_error, pos_integer(), String.t()}
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

  # Defense-in-depth after the body is fully received (Req has no portable
  # streaming size cap). 2 MiB is well above any sane extraction JSON
  # reply. Binary bodies only: an endpoint answering with a JSON
  # content-type bypasses this cap — Req decodes the body before we see
  # it. Error reasons are bounded separately: body_preview/1 flattens
  # every error body to a capped string, so a decoded map cannot ride
  # {:api_error, _, body} / {:bad_request, body} into Result.errors.
  @max_response_body_bytes 2 * 1024 * 1024
  # Reason-payload ceiling, mirroring WireFormat's invalid-format preview.
  @max_error_body_bytes 4_096

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
    user_opts = Keyword.get(opts, :req_options) || []

    # Resolve :headers before the keyword merge: Keyword.merge replaces the
    # whole value, which would wipe provider auth when a caller adds one
    # custom header (every chunk 401s; 4xx is never retried). Normalize
    # map/list shapes, Map.merge per-key, then attach once.
    headers =
      merge_headers(
        normalize_headers(Keyword.get(req_opts, :headers)),
        normalize_headers(Keyword.get(user_opts, :headers))
      )

    @http_defaults
    |> Keyword.merge(Keyword.delete(req_opts, :headers))
    |> Keyword.merge(Keyword.delete(user_opts, :headers))
    |> put_headers(headers)
  end

  defp merge_headers(%{} = provider, %{} = user), do: Map.merge(provider, user)
  defp merge_headers(%{} = provider, nil), do: provider
  defp merge_headers(nil, %{} = user), do: user
  defp merge_headers(nil, nil), do: nil

  defp put_headers(opts, nil), do: opts
  defp put_headers(opts, headers), do: Keyword.put(opts, :headers, headers)

  # Header names normalize exactly as Req.Fields does — atom underscores
  # become dashes, everything downcases — so the per-key merge sees one
  # key per header and Req never receives two casings of the same name
  # (it would concatenate both values: broken auth again). Duplicate
  # names in a list concatenate in order, also matching Req.
  defp normalize_headers(nil), do: nil

  defp normalize_headers(headers) when is_map(headers) or is_list(headers) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      Map.update(acc, normalize_header_name(name), value, &(List.wrap(&1) ++ List.wrap(value)))
    end)
  end

  defp normalize_headers(headers) do
    raise ArgumentError,
          "headers must be a map or a list of {name, value} pairs, got: #{inspect(headers)}"
  end

  defp normalize_header_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", "-")
    |> String.downcase()
  end

  defp normalize_header_name(name) when is_binary(name), do: String.downcase(name)

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
  the HTTP status code, `:transport_error` when no response arrived, or
  `:body_too_large` when the response body exceeded the size cap.
  """
  @spec request(Req.Request.t(), keyword(), map(), (term() ->
                                                      {:ok, String.t()} | {:error, error()})) ::
          {:ok, Response.t()} | {:error, error()}
  def request(req, request_opts, metadata, parse_response) do
    :telemetry.span([:lang_extract, :request], metadata, fn ->
      raw = Req.post(req, request_opts)

      case reject_oversize_body(raw) do
        :ok ->
          usage = usage_measurements(raw)

          {
            wrap_response(parse_response.(raw), usage),
            usage,
            Map.put(metadata, :status, response_status(raw))
          }

        {:error, _} = error ->
          {error, %{}, Map.put(metadata, :status, :body_too_large)}
      end
    end)
  end

  # Scope and limits of the binary-only check: see @max_response_body_bytes.
  defp reject_oversize_body({:ok, %Req.Response{body: body}})
       when is_binary(body) and byte_size(body) > @max_response_body_bytes do
    {:error,
     {:api_error, 413,
      "response body exceeds #{@max_response_body_bytes} bytes (got #{byte_size(body)})"}}
  end

  defp reject_oversize_body(_raw), do: :ok

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
    {:error, {:bad_request, body_preview(body)}}
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
    {:error, {:api_error, status, body_preview(body)}}
  end

  def map_response({:error, exception}, _) do
    {:error, {:request_error, exception}}
  end

  # Every error body flattens to one bounded string — Req decodes JSON
  # content-types before map_response sees them, so without this a huge
  # decoded map (and the reply it pins via sub-binaries) lives as long as
  # any Result holding the ChunkError. inspect output is fresh binaries,
  # never sub-binaries of the reply; the Serializer already flattens
  # these payloads to strings on encode, so live and loaded reasons now
  # match by construction.
  defp body_preview(body) when is_binary(body), do: bounded_preview(body)

  defp body_preview(body) do
    body
    |> inspect(limit: 100, printable_limit: 500)
    |> bounded_preview()
  end

  defp bounded_preview(text) when byte_size(text) <= @max_error_body_bytes, do: text

  defp bounded_preview(text) do
    prefix = valid_prefix(binary_part(text, 0, @max_error_body_bytes))
    prefix <> "…(#{byte_size(text)} bytes total, truncated)"
  end

  # The cut can land mid-character; trim trailing bytes until the prefix
  # is valid on its own — at most 3 steps for UTF-8 input.
  defp valid_prefix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      valid_prefix(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end

  defp retry_after_ms(response) do
    case Req.Response.get_header(response, "retry-after") do
      [seconds | _] ->
        # Negative delay-seconds is malformed per RFC 9110 (and would
        # violate the {:rate_limited, non_neg_integer()} error type) —
        # treated like any other unparseable value.
        case Integer.parse(seconds) do
          {s, ""} when s >= 0 -> s * 1000
          _ -> nil
        end

      [] ->
        nil
    end
  end
end
