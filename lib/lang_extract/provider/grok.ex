defmodule LangExtract.Provider.Grok do
  @moduledoc """
  xAI Grok provider for LLM inference.

  Calls the xAI Chat Completions API via Req — an OpenAI-compatible wire
  shape at `https://api.x.ai`. xAI accepts `max_completion_tokens`
  natively, so unlike the OpenAI provider no wire-key option is needed.
  `temperature` is sent only when the caller sets it — the stance every
  provider here converged on after two temperature-default removals.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Client
  alias LangExtract.Provider

  # Non-reasoning default: extraction gains nothing from extended
  # reasoning, and the reasoning variants cost 4-5x the latency and ~3x
  # the input tokens for identical grounding quality. Callers pick a
  # reasoning model with `model:` when they want one.
  @defaults [
    model: "grok-4.20-0309-non-reasoning",
    max_tokens: 4096,
    base_url: "https://api.x.ai"
  ]

  @impl LangExtract.Provider
  @spec build_http_client(keyword()) :: {:ok, Req.Request.t()} | {:error, :missing_api_key}
  def build_http_client(opts) do
    case Provider.fetch_api_key(opts, "XAI_API_KEY") do
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
      %{provider: :grok, model: model},
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
    messages = build_messages(prompt, json_mode)

    payload =
      %{
        "model" => model,
        "max_completion_tokens" => max_tokens,
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
