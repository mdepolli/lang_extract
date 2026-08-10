defmodule LangExtract.Provider.Gemini do
  @moduledoc """
  Gemini (Google) provider for LLM inference.

  Calls the Gemini generateContent API via Req. The API key is sent via
  the `x-goog-api-key` header, like the other providers' header auth —
  never as a URL query parameter, so request URLs stay loggable.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Client
  alias LangExtract.Provider

  @defaults [
    model: "gemini-3.5-flash",
    max_tokens: 4096,
    temperature: 0,
    base_url: "https://generativelanguage.googleapis.com"
  ]

  @impl LangExtract.Provider
  @spec build_http_client(keyword()) :: {:ok, Req.Request.t()} | {:error, :missing_api_key}
  def build_http_client(opts) do
    case Provider.fetch_api_key(opts, "GEMINI_API_KEY") do
      {:ok, api_key} ->
        %{base_url: base_url} = Provider.common_opts(opts, @defaults)

        req_opts =
          Provider.req_options(opts,
            base_url: base_url,
            headers: %{"x-goog-api-key" => api_key}
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
      %{provider: :gemini, model: model},
      &parse_response/1
    )
  end

  # Pure payload construction: no API key, no transport.
  defp build_inference_request(prompt, opts) do
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

    {path, payload}
  end

  @doc false
  @spec parse_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, String.t()} | {:error, Provider.error()}
  def parse_response(response), do: Provider.map_response(response, &extract_text/1)

  # Gemini splits long completions across parts; every non-thought text
  # part is joined, like the official SDKs do. Function-call parts have
  # no "text"; thought summaries carry "text" with "thought" => true and
  # must be skipped or they prepend prose onto the JSON answer.
  defp extract_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]})
       when is_list(parts) do
    case Enum.flat_map(parts, &answer_text/1) do
      [] -> {:error, :empty_response}
      texts -> {:ok, Enum.join(texts)}
    end
  end

  defp extract_text(_), do: {:error, :empty_response}

  # flat_map: empty list drops thoughts and non-text parts.
  defp answer_text(%{"text" => _text, "thought" => true}), do: []
  defp answer_text(%{"text" => text}) when is_binary(text), do: [text]
  defp answer_text(_part), do: []
end
