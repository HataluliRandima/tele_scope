defmodule TeleScope.Reporters.JSON do
  @moduledoc """
  Structured JSON export.

  A small encoder is included to keep TeleScope dependency-free (Elixir's
  built-in `JSON` module only exists from 1.18). Event names are encoded as
  arrays of strings plus a dotted `id`; MFAs as `"Mod.fun/arity"`; any other
  non-JSON term (pids, refs, tuples) with `inspect/1`.
  """

  alias TeleScope.{Catalog, Event, EventName}
  alias TeleScope.Discovery.CallSite

  @schema_version 1

  @doc "Builds the JSON-ready map."
  def to_map(%Catalog{} = catalog, opts \\ []) do
    diagnostics =
      Keyword.get_lazy(opts, :diagnostics, fn -> TeleScope.Diagnostics.run(catalog) end)

    metrics = Keyword.get(opts, :metrics)

    %{
      schema_version: @schema_version,
      generator: "tele_scope #{Application.spec(:tele_scope, :vsn) || "dev"}",
      environment: %{
        otp_release: System.otp_release(),
        elixir: System.version(),
        telemetry: to_string(Application.spec(:telemetry, :vsn) || "unknown")
      },
      summary: Catalog.summary(catalog),
      static:
        catalog.static &&
          Map.update(catalog.static, :no_debug_info, [], &Enum.map(&1, fn m -> inspect(m) end)),
      runtime: catalog.runtime,
      events: Enum.map(Catalog.events(catalog), &event/1),
      patterns: Enum.map(Map.values(catalog.patterns), &pattern/1),
      spans: Enum.map(Catalog.spans(catalog), fn {p, roles} -> Map.put(roles, :prefix, p) end),
      diagnostics: diagnostics,
      metric_suggestions: metrics
    }
  end

  @doc "Encodes the report as a JSON string."
  def render(catalog, opts \\ []),
    do: catalog |> to_map(opts) |> encode() |> IO.iodata_to_binary()

  defp event(%Event{} = e) do
    %{
      id: EventName.dotted(e.name),
      name: e.name,
      status: Event.status(e),
      confidence: Event.confidence(e),
      sources: e.sources |> MapSet.to_list() |> Enum.sort(),
      apps: e.apps |> MapSet.to_list() |> Enum.sort(),
      span: e.span,
      call_sites: Enum.map(e.call_sites, &site/1),
      rule_reasons: Enum.map(e.rule_reasons, &Map.take(&1, [:rule, :reason])),
      observed: e.observed,
      count: e.count,
      count_estimated: e.count_estimated,
      first_seen_at: e.first_seen_at,
      last_seen_at: e.last_seen_at,
      measurements: stats(e.measurements),
      metadata: stats(e.metadata),
      processes: e.processes,
      handlers: e.handlers,
      static_handlers: e.static_handlers,
      metrics: e.metrics,
      declaration: e.declaration
    }
  end

  defp stats(map) do
    Map.new(map, fn {k, s} ->
      {k,
       %{
         presence: Float.round(s.presence * 1.0, 4),
         types: Map.new(s.types, fn {t, n} -> {TeleScope.Runtime.Shape.format_type(t), n} end)
       }}
    end)
  end

  defp pattern(p) do
    %{
      pattern: EventName.format(p.pattern),
      classification: p.classification,
      matched: Enum.map(p.matched, &EventName.dotted/1),
      call_sites: Enum.map(p.call_sites, &site/1)
    }
  end

  defp site(%CallSite{} = s) do
    %{
      kind: s.kind,
      app: s.app,
      module: s.module,
      function: s.function && "#{elem(s.function, 0)}/#{elem(s.function, 1)}",
      file: s.file,
      line: s.line,
      via: via(s.via)
    }
  end

  defp via(:direct), do: "direct"
  defp via({:wrapper, {m, f, a}, line}), do: "wrapper #{inspect(m)}.#{f}/#{a} (line #{line})"
  defp via({:rule, rule}), do: "rule #{inspect(rule)}"
  defp via(other), do: inspect(other)

  ## encoder -------------------------------------------------------------------

  @doc false
  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(a) when is_atom(a), do: string(module_or_atom(a))

  def encode(b) when is_binary(b),
    do: if(String.valid?(b), do: string(b), else: string(inspect(b)))

  def encode(n) when is_integer(n), do: Integer.to_string(n)
  def encode(f) when is_float(f), do: :erlang.float_to_binary(f, [:short])
  def encode(%MapSet{} = s), do: s |> MapSet.to_list() |> encode()
  def encode(%_{} = struct), do: struct |> Map.from_struct() |> encode()

  def encode(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> [string(key(k)), ?:, encode(v)] end)
      |> Enum.intersperse(?,)

    [?{, inner, ?}]
  end

  def encode({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a),
    do: string("#{inspect(m)}.#{f}/#{a}")

  def encode(list) when is_list(list) do
    if List.improper?(list),
      do: string(inspect(list)),
      else: [?[, list |> Enum.map(&encode/1) |> Enum.intersperse(?,), ?]]
  end

  def encode(other), do: string(inspect(other))

  defp key(k) when is_binary(k), do: if(String.valid?(k), do: k, else: inspect(k))
  defp key(k) when is_atom(k), do: module_or_atom(k)
  defp key(k), do: inspect(k)

  defp module_or_atom(a) do
    case Atom.to_string(a) do
      "Elixir." <> rest -> rest
      s -> s
    end
  end

  defp string(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")
      |> escape_control()

    [?", escaped, ?"]
  end

  defp escape_control(s) do
    for <<c::utf8 <- s>>, into: "" do
      if c < 0x20,
        do: "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0"),
        else: <<c::utf8>>
    end
  end
end
