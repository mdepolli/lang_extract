defmodule LangExtract.Provider.Claude do
  @moduledoc """
  Claude (Anthropic) provider for LLM inference.

  Calls the Anthropic Messages API via Req.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Provider

  # No :temperature default — claude-sonnet-5 rejects non-default sampling
  # params with a 400, so it's only sent when the caller sets it.
  @defaults [
    model: "claude-sonnet-5",
    max_tokens: 4096,
    base_url: "https://api.anthropic.com"
  ]
  @api_version "2023-06-01"

  @impl true
  @spec build_http_client(keyword()) :: {:ok, Req.Request.t()} | {:error, :missing_api_key}
  def build_http_client(opts) do
    with {:ok, api_key} <- Provider.fetch_api_key(opts, "ANTHROPIC_API_KEY") do
      %{base_url: base_url} = Provider.common_opts(opts, @defaults)

      req_opts =
        Provider.req_options(opts,
          base_url: base_url,
          headers: %{
            "x-api-key" => api_key,
            "anthropic-version" => @api_version
          }
        )

      {:ok, Req.new(req_opts)}
    end
  end

  @impl true
  @spec infer(String.t(), keyword()) :: {:ok, Provider.Response.t()} | {:error, Provider.error()}
  def infer(prompt, opts) do
    with {:ok, {req, request_opts}} <- build_request(prompt, opts) do
      %{model: model} = Provider.common_opts(opts, @defaults)

      Provider.request(
        req,
        request_opts,
        %{provider: :claude, model: model},
        &parse_response/1
      )
    end
  end

  @doc false
  @spec build_request(String.t(), keyword()) ::
          {:ok, {Req.Request.t(), keyword()}} | {:error, :missing_api_key}
  def build_request(prompt, opts) do
    with {:ok, req} <- Provider.resolve_http_client(opts, &build_http_client/1) do
      %{model: model, max_tokens: max_tokens, temperature: temperature} =
        Provider.common_opts(opts, @defaults)

      payload =
        %{
          "model" => model,
          "max_tokens" => max_tokens,
          "messages" => [%{"role" => "user", "content" => prompt}]
        }
        |> maybe_put_temperature(temperature)

      {:ok, {req, [url: "/v1/messages", json: payload]}}
    end
  end

  @doc false
  @spec parse_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, String.t()} | {:error, Provider.error()}
  def parse_response(response), do: Provider.map_response(response, &extract_text/1)

  defp extract_text(%{"content" => [_ | _] = blocks}) do
    case Enum.find(blocks, &(&1["type"] == "text")) do
      %{"text" => text} when is_binary(text) -> {:ok, text}
      _ -> {:error, :empty_response}
    end
  end

  defp extract_text(_), do: {:error, :empty_response}

  defp maybe_put_temperature(payload, nil), do: payload

  defp maybe_put_temperature(payload, temperature) do
    Map.put(payload, "temperature", temperature)
  end
end
