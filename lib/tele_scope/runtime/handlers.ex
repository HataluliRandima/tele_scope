defmodule TeleScope.Runtime.Handlers do
  @moduledoc """
  Runtime handler inspection.

  `:telemetry.list_handlers([])` enumerates **all** handlers (verified on
  telemetry 1.x: the empty prefix matches every event; `attach_many/4`
  handlers appear once per event).

  Invocation tracking uses `call_count` tracing on each handler's underlying
  function. Call counting needs no tracer process and sends no messages.
  Anonymous handlers are resolved to their compiled local function
  (`-fun-N-` with arity = fun arity + captured variables).

  Caveat: counts are per *function*. If several handler ids share one
  function (common with `attach_many/4` or reporters reusing a callback),
  the count is shared too; `per_handler_exact?` is false in that case.

  Handler `config` terms are never copied into results (they may contain
  credentials); only their type is reported.
  """

  @compile {:no_warn_undefined, :trace}

  alias TeleScope.Runtime.Shape

  @doc "All handlers except TeleScope's own, normalized."
  def list do
    :telemetry.list_handlers([])
    |> Enum.reject(&own?/1)
    |> Enum.map(fn h ->
      %{
        id: h.id,
        event_name: h.event_name,
        function: describe_fun(h.function),
        config_type: Shape.type(h.config)
      }
    end)
  end

  @doc "Handlers grouped by event name."
  def by_event(handlers \\ list()), do: Enum.group_by(handlers, & &1.event_name)

  defp own?(%{id: {TeleScope.Runtime.Observer, _}}), do: true
  defp own?(%{id: {{TeleScope.Runtime.Observer, _}, _}}), do: true
  defp own?(_), do: false

  @doc false
  def describe_fun(fun) when is_function(fun) do
    info = Function.info(fun)

    mfa =
      case info[:type] do
        :external -> {info[:module], info[:name], info[:arity]}
        :local -> {info[:module], info[:name], info[:arity] + length(info[:env] || [])}
      end

    %{type: info[:type], module: info[:module], name: info[:name], mfa: mfa}
  end

  def describe_fun(_), do: %{type: :unknown, module: nil, name: nil, mfa: nil}

  ## invocation tracking -------------------------------------------------------

  @doc """
  Starts `call_count` tracing for the handler functions. Returns a tracker
  that must be passed to `invocation_counts/1` and `stop_tracking/1`.

  Uses an isolated trace session on OTP 27+, global call_count on OTP 26.
  """
  def track(handlers) do
    backend = TeleScope.Runtime.Tracer.capabilities().default_backend

    session =
      case backend do
        :session -> :trace.session_create(:tele_scope_handlers, self(), [])
        :legacy -> nil
      end

    # OTP 26 call_count patterns are VM-global and survive the owner; a
    # janitor removes them if the owner is killed. (Sessions are destroyed
    # automatically with their owner.)
    janitor =
      if backend == :legacy do
        owner = self()
        spawn(fn -> legacy_janitor(Process.monitor(owner), []) end)
      end

    track_more(
      %{backend: backend, session: session, mfas: [], tracked_at: %{}, janitor: janitor},
      handlers
    )
  end

  defp legacy_janitor(ref, mfas) do
    receive do
      {:mfas, more} ->
        legacy_janitor(ref, more ++ mfas)

      :done ->
        :ok

      {:DOWN, ^ref, :process, _, _} ->
        for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local, :call_count])
        :ok
    end
  end

  @doc """
  Adds call counting for handlers attached after tracking started (e.g. when
  the capture begins before the application boots). Counts for such handlers
  start when they are first seen.
  """
  def track_more(tracker, handlers) do
    new =
      handlers
      |> Enum.map(& &1.function.mfa)
      |> Enum.reject(&(is_nil(&1) or &1 in tracker.mfas))
      |> Enum.uniq()

    traced =
      Enum.filter(new, fn mfa ->
        n =
          case tracker.backend do
            :session -> :trace.function(tracker.session, mfa, true, [:local, :call_count])
            :legacy -> :erlang.trace_pattern(mfa, true, [:local, :call_count])
          end

        n > 0
      end)

    now = System.system_time(:millisecond)
    if tracker[:janitor] && traced != [], do: send(tracker.janitor, {:mfas, traced})

    %{
      tracker
      | mfas: tracker.mfas ++ traced,
        tracked_at: Map.merge(tracker.tracked_at, Map.new(traced, &{&1, now}))
    }
  end

  @doc "Handler ids sharing one function: `%{mfa => [id]}`."
  def shared_functions(handlers) do
    handlers
    |> Enum.group_by(& &1.function.mfa, & &1.id)
    |> Enum.map(fn {mfa, ids} -> {mfa, Enum.uniq(ids)} end)
    |> Enum.filter(fn {mfa, ids} -> mfa != nil and length(ids) > 1 end)
    |> Map.new()
  end

  @doc "Current invocation counts: `%{mfa => count}`."
  def invocation_counts(%{backend: backend, session: session, mfas: mfas}) do
    Map.new(mfas, fn mfa ->
      res =
        case backend do
          :session -> :trace.info(session, mfa, :call_count)
          :legacy -> :erlang.trace_info(mfa, :call_count)
        end

      case res do
        {:call_count, n} when is_integer(n) -> {mfa, n}
        _ -> {mfa, nil}
      end
    end)
  end

  @doc "Stops call counting."
  def stop_tracking(%{backend: :session, session: session}) do
    :trace.session_destroy(session)
    :ok
  catch
    _, _ -> :ok
  end

  def stop_tracking(%{backend: :legacy, mfas: mfas} = tracker) do
    for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local, :call_count])
    if tracker[:janitor], do: send(tracker.janitor, :done)
    :ok
  end
end
