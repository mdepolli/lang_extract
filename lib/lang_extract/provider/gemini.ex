defmodule LangExtract.Provider.Gemini do
  @moduledoc """
  Gemini (Google) provider for LLM inference.

  Calls the Gemini generateContent API via HTTPower + Finch.
  """

  @behaviour LangExtract.Provider

  @default_model "gemini-2.0-flash"
  @default_max_tokens 4096
  @default_temperature 0
  @default_base_url "https://generativelanguage.googleapis.com"

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
    api_key = Keyword.get(opts, :api_key) || System.get_env("GEMINI_API_KEY")

    if api_key in [nil, ""] do
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
            "content-type" => "application/json"
          }
        )

      path = "/v1beta/models/#{model}:generateContent?key=#{api_key}"

      body =
        Jason.encode!(%{
          "contents" => [%{"parts" => [%{"text" => prompt}]}],
          "generationConfig" => %{
            "temperature" => temperature,
            "maxOutputTokens" => max_tokens,
            "responseMimeType" => "application/json"
          }
        })

      {:ok, {client, path, [body: body]}}
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

  defp extract_text(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]})
       when is_binary(text) do
    {:ok, text}
  end

  defp extract_text(_), do: {:error, :empty_response}
end
