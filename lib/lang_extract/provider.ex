defmodule LangExtract.Provider do
  @moduledoc """
  Behaviour for LLM inference providers.

  Each provider implements `infer/2` which takes a prompt string and returns
  the raw LLM response. Parsing and normalization are the caller's responsibility.

  Shared helpers for API key resolution and HTTP error mapping are provided
  for use by provider implementations.
  """

  @callback infer(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Resolves an API key from opts or an environment variable.

  Returns `{:ok, key}` or `{:error, :missing_api_key}` if nil or empty.
  For use by provider implementations.
  """
  @spec fetch_api_key(keyword(), String.t()) :: {:ok, String.t()} | {:error, :missing_api_key}
  def fetch_api_key(opts, env_var) do
    api_key = Keyword.get(opts, :api_key) || System.get_env(env_var)

    if api_key in [nil, ""] do
      {:error, :missing_api_key}
    else
      {:ok, api_key}
    end
  end

  @doc """
  Extracts common provider options (model, max_tokens, temperature, base_url)
  from opts with provider-specific defaults. For use by provider implementations.
  """
  @spec common_opts(keyword(), keyword()) :: %{
          model: String.t(),
          max_tokens: integer(),
          temperature: number(),
          base_url: String.t()
        }
  def common_opts(opts, defaults) do
    %{
      model: Keyword.get(opts, :model, defaults[:model]),
      max_tokens: Keyword.get(opts, :max_tokens, defaults[:max_tokens]),
      temperature: Keyword.get(opts, :temperature, defaults[:temperature]),
      base_url: Keyword.get(opts, :base_url, defaults[:base_url])
    }
  end

  @doc """
  Builds Req options, including the `:plug` option for testing if present in opts.
  For use by provider implementations.
  """
  @spec req_options(keyword(), keyword()) :: keyword()
  def req_options(opts, req_opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  @doc """
  Maps a Req response to a provider result tuple.

  Delegates to `extract_text` for HTTP 200; maps error status codes and
  network failures to standard error tuples. For use by provider implementations.
  """
  @spec map_response(
          {:ok, Req.Response.t()} | {:error, Exception.t()},
          (term() -> {:ok, String.t()} | {:error, :empty_response})
        ) :: {:ok, String.t()} | {:error, term()}
  def map_response({:ok, %Req.Response{status: 200, body: body}}, extract_text) do
    extract_text.(body)
  end

  def map_response({:ok, %Req.Response{status: 400, body: body}}, _) do
    {:error, {:bad_request, body}}
  end

  def map_response({:ok, %Req.Response{status: 401}}, _) do
    {:error, :unauthorized}
  end

  def map_response({:ok, %Req.Response{status: 429}}, _) do
    {:error, :rate_limited}
  end

  def map_response({:ok, %Req.Response{status: status}}, _) when status >= 500 do
    {:error, :server_error}
  end

  def map_response({:ok, %Req.Response{status: status, body: body}}, _) do
    {:error, {:api_error, status, body}}
  end

  def map_response({:error, exception}, _) do
    {:error, {:request_error, exception}}
  end
end
