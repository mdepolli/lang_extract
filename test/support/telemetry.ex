defmodule LangExtract.Test.Telemetry do
  @moduledoc """
  Captures telemetry events into the test process mailbox as
  `{event, measurements, metadata}` messages, detaching on test exit.

  `attach/1` forwards every matching event. `attach_own/1` forwards only
  events emitted by the test process itself — for events that fire in
  whichever process consumes a stream, so a concurrent test's events
  never reach the mailbox.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def attach(events), do: do_attach(events, &__MODULE__.forward_event/4)

  def attach_own(events), do: do_attach(events, &__MODULE__.forward_own_event/4)

  defp do_attach(events, forward) do
    handler_id = "test-telemetry-#{inspect(self())}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(handler_id, events, forward, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Module-qualified captures, not anonymous fns, so telemetry stores them
  # without the local-handler penalty; the parent pid travels as config.
  def forward_event(event, measurements, metadata, parent) do
    send(parent, {event, measurements, metadata})
  end

  def forward_own_event(event, measurements, metadata, parent) do
    if self() == parent do
      send(parent, {event, measurements, metadata})
    end
  end
end
