defmodule LangExtract.Provider.Claude do
  @moduledoc """
  Claude (Anthropic) provider for LLM inference.

  Calls the Anthropic Messages API via HTTPower + Finch.
  """

  @behaviour LangExtract.Provider

  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 4096
  @default_temperature 0
  @default_base_url "https://api.anthropic.com"
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
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      temperature = Keyword.get(opts, :temperature, @default_temperature)
      base_url = Keyword.get(opts, :base_url, @default_base_url)

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
  def parse_response({:ok, %HTTPower.Response{status: 200, body: body}}) do
    extract_text(body)
  end

  def parse_response({:ok, %HTTPower.Response{status: 400, body: body}}) do
    {:error, {:bad_request, body}}
  end

  def parse_response({:ok, %HTTPower.Response{status: 401}}) do
    {:error, :unauthorized}
  end

  def parse_response({:ok, %HTTPower.Response{status: 429}}) do
    {:error, :rate_limited}
  end

  def parse_response({:ok, %HTTPower.Response{status: status}}) when status >= 500 do
    {:error, :server_error}
  end

  def parse_response({:ok, %HTTPower.Response{status: status, body: body}}) do
    {:error, {:api_error, status, body}}
  end

  def parse_response({:error, %HTTPower.Error{reason: reason}}) do
    {:error, {:request_error, reason}}
  end

  defp extract_text(%{"content" => [_ | _] = blocks}) do
    case Enum.find(blocks, &(&1["type"] == "text")) do
      %{"text" => text} when is_binary(text) -> {:ok, text}
      _ -> {:error, :empty_response}
    end
  end

  defp extract_text(_), do: {:error, :empty_response}
end
