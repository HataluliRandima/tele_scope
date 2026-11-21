# Call-site level static coverage + independent grep baseline.
#   mix run --no-start priv/spike/static_coverage.exs
#
# Baseline: count `:telemetry.execute|span|execute_lazy(` / `telemetry:execute(` occurrences
# in dependency *source* (deps/*/lib, deps/*/src). Comparing with the BEAM
# scanner's direct call sites per app checks that nothing is silently missed.
# (Source counts include macro bodies inside `quote`, which compile into the
# *caller's* module; differences are explained per app below.)
alias TeleScope.Discovery.Scanner
alias TeleScope.EventName

r = Scanner.scan(Scanner.mix_app_dirs() |> Enum.reject(&(elem(&1, 0) == :tele_scope)))

emit_sites =
  Enum.filter(r.sites, &(&1.kind in [:execute, :execute_lazy, :span]))

direct = Enum.filter(emit_sites, &(&1.via == :direct and not Map.get(&1.extra, :wrapper_template, false)))
templates = Enum.filter(emit_sites, &Map.get(&1.extra, :wrapper_template, false))
wrapper_resolved = Enum.filter(emit_sites, &match?({:wrapper, _, _}, &1.via))
rule_sites = Enum.filter(emit_sites, &match?({:rule, _}, &1.via))

classify = fn sites ->
  sites
  |> Enum.map(fn s ->
    classes = Enum.map(s.patterns, &EventName.classify/1) |> Enum.uniq()

    cond do
      classes == [:literal] -> :literal
      :dynamic in classes -> :dynamic
      :invalid in classes -> :invalid
      true -> :partial
    end
  end)
  |> Enum.frequencies()
end

IO.puts("== call-site level (direct telemetry calls, excluding wrapper templates)")
IO.inspect(classify.(direct), label: "direct non-template call sites (#{length(direct)})")
IO.inspect(length(templates), label: "wrapper template call sites (names resolved at callers)")
IO.inspect(classify.(wrapper_resolved), label: "call sites resolved through wrappers (#{length(wrapper_resolved)})")
IO.inspect(classify.(rule_sites), label: "call sites produced by rules (#{length(rule_sites)})")

# effective: every place an event name is *decided* = direct non-template + wrapper call sites + rules
effective = direct ++ wrapper_resolved ++ rule_sites
freq = classify.(effective)
total = length(effective)
IO.puts("\n== effective name-decision sites: #{total}")
for {k, v} <- Enum.sort(freq), do: IO.puts("  #{k}: #{v} (#{Float.round(v * 100 / total, 1)}%)")

IO.puts("\n== grep baseline vs scanner (direct call sites incl. templates) per app")
re = ~r/(:telemetry\.(execute|span|execute_lazy)\(|telemetry:(execute|span|execute_lazy)\()/

source_counts =
  for dir <- Path.wildcard("deps/*") ++ ["."],
      app = if(dir == ".", do: "demo_app", else: Path.basename(dir)),
      files = Path.wildcard(Path.join(dir, "{lib,src}/**/*.{ex,erl}")),
      files != [],
      into: %{} do
    n = files |> Enum.map(&length(Regex.scan(re, File.read!(&1)))) |> Enum.sum()
    {app, n}
  end

scanner_counts =
  emit_sites
  |> Enum.filter(&(&1.via == :direct))
  |> Enum.group_by(&to_string(&1.app))
  |> Map.new(fn {app, sites} -> {app, sites |> Enum.uniq_by(&{&1.module, &1.line, &1.kind}) |> length()} end)

apps = (Map.keys(source_counts) ++ Map.keys(scanner_counts)) |> Enum.uniq() |> Enum.sort()

for app <- apps, (Map.get(source_counts, app, 0) + Map.get(scanner_counts, app, 0)) > 0 do
  IO.puts("  #{String.pad_trailing(app, 22)} source=#{Map.get(source_counts, app, 0)}  scanner=#{Map.get(scanner_counts, app, 0)}")
end

IO.puts("\nscan stats: #{inspect(r.stats)}")
