defmodule LangExtract.Provider.OpenAI do
  @moduledoc """
  OpenAI provider for LLM inference.

  Calls the OpenAI Chat Completions API via HTTPower + Finch.
  """

  @behaviour LangExtract.Provider

  @default_model "gpt-4o-mini"
  @default_max_tokens 4096
  @default_temperature 0
  @default_base_url "https://api.openai.com"

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
    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    if api_key in [nil, ""] do
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      temperature = Keyword.get(opts, :temperature, @default_temperature)
      base_url = Keyword.get(opts, :base_url, @default_base_url)
      json_mode = Keyword.get(opts, :json_mode, true)

      client =
        HTTPower.new(
          base_url: base_url,
          headers: %{
            "authorization" => "Bearer #{api_key}",
            "content-type" => "application/json"
          }
        )

      messages = build_messages(prompt, json_mode)

      request_body =
        %{
          "model" => model,
          "max_tokens" => max_tokens,
          "temperature" => temperature,
          "messages" => messages
        }
        |> maybe_add_response_format(json_mode)

      body = Jason.encode!(request_body)

      {:ok, {client, "/v1/chat/completions", [body: body]}}
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

  defp build_messages(prompt, true) do
    [
      %{"role" => "system", "content" => "Respond with JSON."},
      %{"role" => "user", "content" => prompt}
    ]
  end

  defp build_messages(prompt, false) do
    [%{"role" => "user", "content" => prompt}]
  end

  defp maybe_add_response_format(body, true) do
    Map.put(body, "response_format", %{"type" => "json_object"})
  end

  defp maybe_add_response_format(body, false), do: body

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp extract_text(_), do: {:error, :empty_response}
end
