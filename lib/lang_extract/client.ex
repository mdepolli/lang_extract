defmodule LangExtract.Client do
  @moduledoc """
  A configured LLM client.

  Created via `LangExtract.new/2`. Hold it and pass it to `run/4` /
  `stream/4`. Opaque — match on it, don't build it by hand.
  """

  @type t :: %__MODULE__{
          provider: module(),
          options: keyword(),
          http_client: Req.Request.t() | nil
        }

  @derive {Inspect, except: [:options, :http_client]}
  @enforce_keys [:provider]
  defstruct [:provider, :http_client, options: []]
end
