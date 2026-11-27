defmodule TeleScope.CaptureError do
  @moduledoc """
  Raised by `TeleScope.capture/2` and `TeleScope.stop_capture/2` when a
  runtime capture cannot be started or is no longer running.

  `reason` is the underlying error term; `message/1` explains it.
  """
  defexception [:reason]

  @impl true
  def message(%{reason: reason}), do: "runtime capture failed: " <> describe(reason)

  @doc false
  def describe({:invalid_option, {:duration, value}}),
    do: "invalid :duration #{inspect(value)}; expected a positive integer (milliseconds)"

  def describe({:invalid_option, {key, value}}),
    do: "invalid option #{inspect(key)}: #{inspect(value)}"

  def describe({:observer_failed, {%{__exception__: true} = e, _stack}}),
    do: "the observer could not start: " <> Exception.message(e)

  def describe({:observer_failed, reason}),
    do: "the observer could not start: #{inspect(reason)}"

  def describe(:not_running),
    do:
      "the capture is not running (it was already stopped, or the process that started it exited)"

  def describe(reason), do: inspect(reason)
end
