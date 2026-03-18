defmodule LangExtract.Provider.Claude do
  @moduledoc """
  Claude (Anthropic) provider for LLM inference.

  Calls the Anthropic Messages API via HTTPower + Finch.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Provider

  @defaults [
    model: "claude-sonnet-4-20250514",
    max_tokens: 4096,
    temperature: 0,
    base_url: "https://api.anthropic.com"
  ]
  @api_version "2023-06-01"

  @impl true
  @spec infer(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def infer(prompt, opts \\ []) do
    with {:ok, {client, path, request_opts}} <- build_request(prompt, opts) do
      client
      |> HTTPower.post(path, request_opts)
      |> parse_response()
    end
  end

  @doc false
  @spec build_request(String.t(), keyword()) ::
          {:ok, {HTTPower.client(), String.t(), keyword()}} | {:error, :missing_api_key}
  def build_request(prompt, opts) do
    with {:ok, api_key} <- Provider.fetch_api_key(opts, "ANTHROPIC_API_KEY") do
      %{model: model, max_tokens: max_tokens, temperature: temperature, base_url: base_url} =
        Provider.common_opts(opts, @defaults)

      client =
        HTTPower.new(
          base_url: base_url,
          headers: %{
            "x-api-key" => api_key,
            "anthropic-version" => @api_version,
            "content-type" => "application/json"
          }
        )

      body =
        Jason.encode!(%{
          "model" => model,
          "max_tokens" => max_tokens,
          "temperature" => temperature,
          "messages" => [%{"role" => "user", "content" => prompt}]
        })

      {:ok, {client, "/v1/messages", [body: body]}}
    end
  end

  @doc false
  @spec parse_response({:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def parse_response(response), do: Provider.map_response(response, &extract_text/1)

  defp extract_text(%{"content" => [_ | _] = blocks}) do
    case Enum.find(blocks, &(&1["type"] == "text")) do
      %{"text" => text} when is_binary(text) -> {:ok, text}
      _ -> {:error, :empty_response}
    end
  end

  defp extract_text(_), do: {:error, :empty_response}
end
