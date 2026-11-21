defmodule TeleScope.Discovery.CallSite do
  @moduledoc """
  A statically discovered call relevant to telemetry.

  `kind`:
    * `:execute` / `:execute_lazy` - emits `patterns`
    * `:span` - emits `prefix ++ [:start | :stop | :exception]`; `patterns` hold the prefix
    * `:attach` / `:attach_many` / `:detach` - handler registration (see `:handler`)
    * `:metric` - a `Telemetry.Metrics` definition referencing an event
    * `:rule` - an event derived by a library rule (see `:via`)

  `via` explains how the name was obtained:
    * `:direct` - from the telemetry call itself (possibly after local
      constant propagation)
    * `{:wrapper, {m, f, a}, wrapper_line}` - argument substituted into a
      wrapper function that calls telemetry
    * `{:rule, rule_module}` - produced by a configuration/library rule
  """

  @type t :: %__MODULE__{
          kind: atom(),
          app: atom() | nil,
          module: module(),
          function: {atom(), non_neg_integer()} | nil,
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          patterns: [TeleScope.EventName.pattern()],
          via: term(),
          handler: map() | nil,
          extra: map()
        }

  defstruct kind: nil,
            app: nil,
            module: nil,
            function: nil,
            file: nil,
            line: nil,
            patterns: [],
            via: :direct,
            handler: nil,
            extra: %{}

  @doc "Location string `file:line` (or module when the file is unknown)."
  def location(%__MODULE__{file: nil, module: m, line: l}), do: "#{inspect(m)}:#{l}"
  def location(%__MODULE__{file: f, line: l}), do: "#{f}:#{l}"

  @doc "Key used to deduplicate call sites discovered by several rounds."
  def key(%__MODULE__{} = s),
    do: {s.kind, s.module, s.function, s.line, s.patterns, s.via, s.handler}
end
