defmodule LangExtract.Provider.OpenAI do
  @moduledoc """
  OpenAI provider for LLM inference.

  Calls the OpenAI Chat Completions API via Req.
  """

  @behaviour LangExtract.Provider

  alias LangExtract.Provider

  @defaults [
    model: "gpt-4o-mini",
    max_tokens: 4096,
    temperature: 0,
    base_url: "https://api.openai.com"
  ]

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
    with {:ok, api_key} <- Provider.fetch_api_key(opts, "OPENAI_API_KEY") do
      %{model: model, max_tokens: max_tokens, temperature: temperature, base_url: base_url} =
        Provider.common_opts(opts, @defaults)

      json_mode = Keyword.get(opts, :json_mode, true)

      req_opts =
        Provider.req_options(opts,
          base_url: base_url,
          retry: false,
          headers: %{"authorization" => "Bearer #{api_key}"}
        )

      req = Req.new(req_opts)

      messages = build_messages(prompt, json_mode)

      payload =
        %{
          "model" => model,
          "max_tokens" => max_tokens,
          "temperature" => temperature,
          "messages" => messages
        }
        |> maybe_add_response_format(json_mode)

      {:ok, {req, [url: "/v1/chat/completions", json: payload]}}
    end
  end

  @doc false
  @spec parse_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, String.t()} | {:error, term()}
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
