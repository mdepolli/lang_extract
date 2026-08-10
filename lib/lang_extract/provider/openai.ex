defmodule LangExtract.Provider.OpenAI do
  @moduledoc """
  OpenAI provider for LLM inference.

  Calls the OpenAI Chat Completions API via Req.

  `:token_limit_key` picks the wire key carrying the completion-token cap:
  `:max_completion_tokens` (default — openai.com, where reasoning models
  reject the deprecated key) or `:max_tokens` for OpenAI-compatible
  endpoints whose servers only know the deprecated key. Older compat
  builds (Ollama, LocalAI, llama.cpp) silently drop unknown keys, so the
  wrong choice there truncates replies at the server's own default length
  — set `token_limit_key: :max_tokens` alongside `base_url` for those.
  The library option stays `:max_tokens` either way; only the wire key
  differs.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Client
  alias LangExtract.Provider

  # No :temperature default — o-series/reasoning models reject any
  # non-default temperature with a 400, so it's only sent when the caller
  # sets it (same stance as Claude).
  @defaults [
    model: "gpt-4o-mini",
    max_tokens: 4096,
    base_url: "https://api.openai.com"
  ]

  @impl LangExtract.Provider
  @spec build_http_client(keyword()) :: {:ok, Req.Request.t()} | {:error, :missing_api_key}
  def build_http_client(opts) do
    case Provider.fetch_api_key(opts, "OPENAI_API_KEY") do
      {:ok, api_key} ->
        %{base_url: base_url} = Provider.common_opts(opts, @defaults)

        req_opts =
          Provider.req_options(opts,
            base_url: base_url,
            headers: %{"authorization" => "Bearer #{api_key}"}
          )

        {:ok, Req.new(req_opts)}

      {:error, _} = error ->
        error
    end
  end

  @impl LangExtract.Provider
  @spec infer(Client.t(), String.t()) ::
          {:ok, Provider.Response.t()} | {:error, Provider.error()}
  def infer(%Client{http_client: req, options: opts}, prompt) do
    {url, json} = build_inference_request(prompt, opts)
    %{model: model} = Provider.common_opts(opts, @defaults)

    Provider.request(
      req,
      [url: url, json: json],
      %{provider: :openai, model: model},
      &parse_response/1
    )
  end

  # Public only as a test seam: pure payload construction, no API key or
  # transport involved.
  @doc false
  @spec build_inference_request(String.t(), keyword()) :: {String.t(), map()}
  def build_inference_request(prompt, opts) do
    %{model: model, max_tokens: max_tokens, temperature: temperature} =
      Provider.common_opts(opts, @defaults)

    json_mode = Keyword.get(opts, :json_mode, true)
    token_limit_key = Keyword.get(opts, :token_limit_key, :max_completion_tokens)
    messages = build_messages(prompt, json_mode)

    payload =
      %{
        "model" => model,
        token_limit_wire_key!(token_limit_key) => max_tokens,
        "messages" => messages
      }
      |> maybe_put_temperature(temperature)
      |> maybe_put_response_format(json_mode)

    {"/v1/chat/completions", payload}
  end

  @doc false
  @spec parse_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, String.t()} | {:error, Provider.error()}
  def parse_response(response), do: Provider.map_response(response, &extract_text/1)

  # See the moduledoc: no heuristic can pick the right key per server
  # (Azure lives off-host but wants the new key; old compat builds only
  # know the deprecated one), so the choice is explicit.
  defp token_limit_wire_key!(:max_completion_tokens), do: "max_completion_tokens"
  defp token_limit_wire_key!(:max_tokens), do: "max_tokens"

  defp token_limit_wire_key!(other) do
    raise ArgumentError,
          ":token_limit_key must be :max_completion_tokens or :max_tokens, " <>
            "got: #{inspect(other)}"
  end

  defp build_messages(prompt, true) do
    [
      %{"role" => "system", "content" => "Respond with JSON."},
      %{"role" => "user", "content" => prompt}
    ]
  end

  defp build_messages(prompt, false) do
    [%{"role" => "user", "content" => prompt}]
  end

  defp maybe_put_temperature(payload, nil), do: payload

  defp maybe_put_temperature(payload, temperature) do
    Map.put(payload, "temperature", temperature)
  end

  defp maybe_put_response_format(payload, true) do
    Map.put(payload, "response_format", %{"type" => "json_object"})
  end

  defp maybe_put_response_format(payload, false), do: payload

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp extract_text(_), do: {:error, :empty_response}
end
