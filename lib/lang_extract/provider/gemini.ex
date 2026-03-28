defmodule LangExtract.Provider.Gemini do
  @moduledoc """
  Gemini (Google) provider for LLM inference.

  Calls the Gemini generateContent API via Req.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Provider

  @defaults [
    model: "gemini-2.0-flash",
    max_tokens: 4096,
    temperature: 0,
    base_url: "https://generativelanguage.googleapis.com"
  ]

  # Gemini passes API key as a query param per request (not a header), so it can't
  # be baked into the Req struct. We still validate the key here for fail-fast at new/2.
  @impl true
  @spec build_http_client(keyword()) :: {:ok, Req.Request.t()} | {:error, :missing_api_key}
  def build_http_client(opts) do
    with {:ok, _api_key} <- Provider.fetch_api_key(opts, "GEMINI_API_KEY") do
      %{base_url: base_url} = Provider.common_opts(opts, @defaults)
      req_opts = Provider.req_options(opts, base_url: base_url, retry: false)
      {:ok, Req.new(req_opts)}
    end
  end

  @impl true
  @spec infer(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def infer(prompt, opts \\ []) do
    with {:ok, {req, request_opts}} <- build_request(prompt, opts) do
      req
      |> Req.post(request_opts)
      |> parse_response()
    end
  end

  @doc false
  @spec build_request(String.t(), keyword()) ::
          {:ok, {Req.Request.t(), keyword()}} | {:error, :missing_api_key}
  def build_request(prompt, opts) do
    with {:ok, req} <- Provider.resolve_http_client(opts, &build_http_client/1),
         {:ok, api_key} <- Provider.fetch_api_key(opts, "GEMINI_API_KEY") do
      %{model: model, max_tokens: max_tokens, temperature: temperature} =
        Provider.common_opts(opts, @defaults)

      path = "/v1beta/models/#{model}:generateContent"

      payload = %{
        "contents" => [%{"parts" => [%{"text" => prompt}]}],
        "generationConfig" => %{
          "temperature" => temperature,
          "maxOutputTokens" => max_tokens,
          "responseMimeType" => "application/json"
        }
      }

      {:ok, {req, [url: path, params: [key: api_key], json: payload]}}
    end
  end

  @doc false
  @spec parse_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def parse_response(response), do: Provider.map_response(response, &extract_text/1)

  defp extract_text(%{
         "candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]
       })
       when is_binary(text) do
    {:ok, text}
  end

  defp extract_text(_), do: {:error, :empty_response}
end
