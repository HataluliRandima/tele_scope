defmodule TeleScope.Discovery.Rules.Ecto do
  @moduledoc """
  Resolves Ecto's `telemetry_prefix ++ [:query]` events.

  Ecto adapters emit query events under `telemetry_prefix ++ [:query]` where
  the prefix comes from the repo configuration and defaults to the repo
  module name split and underscored (`MyApp.Repo` -> `[:my_app, :repo]`);
  see `Ecto.Repo.Supervisor.telemetry_prefix/1`.

  Repos are found from two independent sources and unioned:
    * `config :my_app, ecto_repos: [...]` for every scanned application
    * modules declaring `@behaviour Ecto.Repo` in the scanned BEAM files

  Not covered (documented limitation): prefixes changed in a repo's `init/2`
  callback, per-call `:telemetry_event` options, and repos started
  dynamically with a different `:telemetry_prefix`.
  """
  @behaviour TeleScope.Discovery.Rule

  @impl true
  def config_events(%{apps: apps, get_env: get_env, implementations: impls}) do
    from_config =
      for app <- apps,
          repo <- List.wrap(Keyword.get(get_env.(app), :ecto_repos, [])),
          do: {repo, app}

    from_code = for repo <- impls.(Ecto.Repo), do: {repo, nil}

    (from_config ++ from_code)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {repo, app} ->
      app = app || find_app(apps, get_env, repo)
      repo_config = if app, do: Keyword.get(get_env.(app), repo, []), else: []

      {prefix, how} =
        case Keyword.get(repo_config, :telemetry_prefix) do
          prefix when is_list(prefix) and prefix != [] -> {prefix, "configured :telemetry_prefix"}
          _ -> {default_prefix(repo), "default prefix derived from #{inspect(repo)}"}
        end

      %{
        name: prefix ++ [:query],
        kind: :execute,
        app: app,
        reason: "Ecto query event for #{inspect(repo)} (#{how})",
        emitted_by: [Ecto.Adapters.SQL],
        subject: repo,
        # documented as optional by Ecto: present only when applicable (e.g.
        # idle_time only for connections that were idle). Never present under
        # a SQL sandbox (real-app validation, hexpm).
        optional_measurements: [:idle_time, :queue_time, :decode_time]
      }
    end)
  end

  defp find_app(apps, get_env, repo) do
    Enum.find(apps, fn app -> Keyword.has_key?(get_env.(app), repo) end)
  end

  @doc false
  def default_prefix(repo) do
    repo
    |> Module.split()
    |> Enum.map(&(&1 |> Macro.underscore() |> String.to_atom()))
  end
end
