defmodule TeleScope.Discovery.Rule do
  @moduledoc """
  Extension point for library-specific discovery knowledge.

  Some event names are not visible in code at all: they are computed from
  configuration (Ecto's `telemetry_prefix`) or from options passed to a
  library at a call site (`plug Plug.Telemetry, event_prefix: [...]`).
  A rule encodes that knowledge in one of two ways, both optional:

    * **call-site hooks** - `watched_calls/0` lists MFAs; for every call to one
      of them the analyzer invokes `on_call/3` with the *abstract* argument
      expressions and helpers to evaluate them. This is purely static.

    * **configuration hooks** - `config_events/1` receives a context with the
      application environment and the static index (e.g. which modules
      implement a behaviour) and returns resolved events.

  Rules must be pure, fast and must not raise; failures are swallowed by the
  caller and the rule is reported as having produced nothing.

  Third-party libraries (or users) can add rules with the `:rules` option.
  """

  alias TeleScope.EventName

  @type kind :: :execute | :span
  @type on_call_result :: [{kind(), [EventName.pattern()], map()}]

  @type config_ctx :: %{
          apps: [atom()],
          get_env: (atom() -> keyword()),
          implementations: (module() -> [module()])
        }

  @type config_event :: %{
          required(:name) => [atom()],
          required(:kind) => kind(),
          required(:reason) => String.t(),
          optional(:app) => atom(),
          optional(:emitted_by) => [module()],
          optional(:optional_measurements) => [atom()]
        }

  @callback watched_calls() :: [mfa()]
  @callback on_call(mfa(), [tuple()], map()) :: on_call_result()
  @callback config_events(config_ctx()) :: [config_event()]
  @optional_callbacks watched_calls: 0, on_call: 3, config_events: 1

  @doc "Rules shipped with TeleScope."
  def default_rules do
    [TeleScope.Discovery.Rules.Ecto, TeleScope.Discovery.Rules.PlugTelemetry]
  end

  @doc "Runs `config_events/1` for every rule, isolating failures."
  def run_config(rules, ctx) do
    Enum.flat_map(rules, fn rule ->
      if Code.ensure_loaded?(rule) and function_exported?(rule, :config_events, 1) do
        try do
          rule.config_events(ctx) |> Enum.map(&Map.put(&1, :rule, rule))
        rescue
          e ->
            [%{rule: rule, error: Exception.message(e)}]
        catch
          kind, reason ->
            [%{rule: rule, error: Exception.format_banner(kind, reason)}]
        end
      else
        []
      end
    end)
  end
end
