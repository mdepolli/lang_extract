defmodule LangExtract.Provider.Gemini do
  @moduledoc """
  Gemini (Google) provider for LLM inference.

  Calls the Gemini generateContent API via HTTPower + Finch.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Provider

  @defaults [
    model: "gemini-2.0-flash",
    max_tokens: 4096,
    temperature: 0,
    base_url: "https://generativelanguage.googleapis.com"
  ]

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
    with {:ok, api_key} <- Provider.fetch_api_key(opts, "GEMINI_API_KEY") do
      %{model: model, max_tokens: max_tokens, temperature: temperature, base_url: base_url} =
        Provider.common_opts(opts, @defaults)

      client =
        HTTPower.new(base_url: base_url)

      path = "/v1beta/models/#{model}:generateContent?key=#{api_key}"

      payload = %{
        "contents" => [%{"parts" => [%{"text" => prompt}]}],
        "generationConfig" => %{
          "temperature" => temperature,
          "maxOutputTokens" => max_tokens,
          "responseMimeType" => "application/json"
        }
      }

      {:ok, {client, path, [json: payload]}}
    end
  end

  @doc false
  @spec parse_response({:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}) ::
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
