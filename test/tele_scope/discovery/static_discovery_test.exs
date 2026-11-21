defmodule TeleScope.Discovery.StaticDiscoveryTest do
  # compiler options are global -> not async
  use ExUnit.Case, async: false

  import TeleScope.Test.Fixtures
  alias TeleScope.Discovery.{Beam, CallSite}
  alias TeleScope.{Catalog, Event, EventName}

  @emitters """
  defmodule Fx.Emitters do
    @attr_event [:fx, :attr, :event]

    def literal, do: :telemetry.execute([:fx, :literal], %{}, %{})
    def attribute, do: :telemetry.execute(@attr_event, %{}, %{})

    def local_binding do
      event = [:fx, :bound]
      :telemetry.execute(event, %{}, %{})
    end

    def alternatives(ok?) do
      outcome = if ok?, do: :ok, else: :error
      :telemetry.execute([:fx, :result, outcome], %{}, %{})
    end

    def partial_segment(op), do: :telemetry.execute([:fx, :cache, op], %{}, %{})

    def ecto_style(config) do
      prefix = Keyword.fetch!(config, :telemetry_prefix)
      :telemetry.execute(prefix ++ [:query], %{}, %{})
    end

    def dynamic(name), do: :telemetry.execute(build(name), %{}, %{})
    defp build(name), do: String.split(name, ".") |> Enum.map(&String.to_atom/1)

    def local_fun_name, do: :telemetry.execute(event_name(), %{}, %{})
    defp event_name, do: [:fx, :from_local_fun]

    def span, do: :telemetry.span([:fx, :span], %{}, fn -> {:ok, %{}} end)
    def two_arity, do: :telemetry.execute([:fx, :two], %{})
    def lazy, do: :telemetry.execute_lazy([:fx, :lazy], fn -> {%{}, %{}} end)

    def invalid_atom, do: :telemetry.execute(:not_a_list, %{}, %{})
    def invalid_segment, do: :telemetry.execute([:fx, "string"], %{}, %{})
  end
  """

  @wrappers """
  defmodule Fx.Telemetry do
    def emit(suffix, m \\\\ %{}, md \\\\ %{}), do: :telemetry.execute([:fx | suffix], m, md)
    def start(name, md), do: :telemetry.execute([:fx, name, :start], %{}, md)
    def span(name, md, fun), do: :telemetry.span([:fx, name], md, fun)
    # wrapper of a wrapper
    def stop(name), do: emit([name, :stop])
  end

  defmodule Fx.Caller do
    def a, do: Fx.Telemetry.emit([:order, :created], %{count: 1}, %{})
    def b, do: Fx.Telemetry.emit([:order, :paid])
    def c, do: Fx.Telemetry.start(:request, %{})
    def d, do: Fx.Telemetry.span(:job, %{}, fn -> {:ok, %{}} end)
    def e, do: Fx.Telemetry.stop(:request)
    def f(unknown), do: Fx.Telemetry.start(unknown, %{})
  end
  """

  @handlers """
  defmodule Fx.Handlers do
    @events [[:fx, :literal], [:fx, :two]]
    def attach do
      :telemetry.attach("fx-remote", [:fx, :literal], &__MODULE__.handle/4, nil)
      :telemetry.attach_many("fx-many", @events, &handle/4, nil)
      :telemetry.attach("fx-anon", [:fx, :lazy], fn _, _, _, _ -> :ok end, nil)
      :telemetry.detach("fx-remote")
    end

    def handle(_, _, _, _), do: :ok

    def metrics do
      [
        Telemetry.Metrics.summary("fx.span.stop.duration", unit: {:native, :millisecond}),
        Telemetry.Metrics.counter("fx.literal.count"),
        Telemetry.Metrics.counter("fx.custom.count", event_name: [:fx, :literal])
      ]
    end
  end
  """

  setup_all do
    dir = tmp_dir("static")
    compile_elixir(@emitters, dir)
    compile_elixir(@wrappers, dir)
    compile_elixir(@handlers, dir)
    %{dir: dir, result: scan([{:fx, dir}])}
  end

  describe "emitters (positive)" do
    test "literal, attribute, local binding, local function", %{result: r} do
      e = emitted(r)
      assert {:execute, "[:fx, :literal]"} in e
      assert {:execute, "[:fx, :attr, :event]"} in e
      assert {:execute, "[:fx, :bound]"} in e
      assert {:execute, "[:fx, :from_local_fun]"} in e
    end

    test "if/case alternatives produce every literal name", %{result: r} do
      e = emitted(r)
      assert {:execute, "[:fx, :result, :ok]"} in e
      assert {:execute, "[:fx, :result, :error]"} in e
    end

    test "partial names", %{result: r} do
      e = emitted(r)
      assert {:execute, "[:fx, :cache, *]"} in e
      assert {:execute, "[**, :query]"} in e
    end

    test "dynamic names", %{result: r} do
      site = Enum.find(r.sites, &(&1.function == {:dynamic, 1}))
      assert [[{:splice, :unknown}]] = site.patterns
      assert EventName.classify(hd(site.patterns)) == :dynamic
    end

    test "span, execute/2 and execute_lazy are recognised", %{result: r} do
      e = emitted(r)
      assert {:span, "[:fx, :span]"} in e
      assert {:execute, "[:fx, :two]"} in e
      assert {:execute_lazy, "[:fx, :lazy]"} in e
    end

    test "call sites carry module, function, file and line", %{result: r} do
      site = Enum.find(r.sites, &(&1.function == {:literal, 0}))
      assert %CallSite{module: Fx.Emitters, app: :fx, kind: :execute, via: :direct} = site
      assert site.file =~ "fixture.ex"
      assert is_integer(site.line) and site.line > 0
    end
  end

  describe "wrapper resolution" do
    test "list parameter wrappers resolved at cross-module call sites", %{result: r} do
      resolved =
        for s <- r.sites,
            match?({:wrapper, _, _}, s.via),
            p <- s.patterns,
            do: {s.module, s.function, p}

      assert {Fx.Caller, {:a, 0}, [:fx, :order, :created]} in resolved
      # default-argument clause (emit/1 -> emit/3)
      assert {Fx.Caller, {:b, 0}, [:fx, :order, :paid]} in resolved
      # atom parameter
      assert {Fx.Caller, {:c, 0}, [:fx, :request, :start]} in resolved
      # wrapper of a wrapper
      assert {Fx.Caller, {:e, 0}, [:fx, :request, :stop]} in resolved
    end

    test "span wrappers keep their span kind", %{result: r} do
      assert Enum.any?(r.sites, &(&1.kind == :span and &1.patterns == [[:fx, :job]]))
    end

    test "unknown arguments stay partial at the caller", %{result: r, dir: dir} do
      site = Enum.find(r.sites, &(&1.module == Fx.Caller and &1.function == {:f, 1}))
      # f/1 passes its own parameter: it is an (unused) intermediate wrapper
      assert site.patterns == [[:fx, {:var, :unknown}, :start]]
      assert site.extra.wrapper_template

      # Patterns aggregate by shape: f/1's template shares the entry of
      # Fx.Telemetry.start/2's template, which is resolved via Fx.Caller.c/0.
      cat = catalog([{:fx, dir}])
      entry = cat.patterns[[:fx, {:var, :unknown}, :start]]
      assert Enum.any?(entry.call_sites, &(&1.module == Fx.Caller))
      assert entry.wrapper_template and entry.wrapper_resolved
      assert [:fx, :request, :start] in entry.matched
      # template-only patterns are never "specific" evidence for consumers
      refute entry in TeleScope.Catalog.specific_patterns(cat)
    end

    test "wrapper templates are reported with parameters forgotten", %{result: r} do
      site =
        Enum.find(
          r.sites,
          &(&1.module == Fx.Telemetry and &1.function == {:emit, 3} and &1.via == :direct)
        )

      assert site.patterns == [[:fx, {:splice, :unknown}]]
      assert site.extra.wrapper_template
    end
  end

  describe "invalid event names (negative)" do
    test "non-list and non-atom segments are classified invalid", %{result: r} do
      for f <- [{:invalid_atom, 0}, {:invalid_segment, 0}] do
        site = Enum.find(r.sites, &(&1.function == f))
        assert site.patterns == [:invalid], "#{inspect(f)}: #{inspect(site.patterns)}"
      end
    end
  end

  describe "handlers and metrics" do
    test "attach / attach_many / detach with handler functions", %{result: r} do
      attaches =
        for s <- r.sites,
            s.kind in [:attach, :attach_many],
            do: {s.handler.id, s.handler.function, s.patterns}

      assert {"fx-remote", {Fx.Handlers, :handle, 4}, [[:fx, :literal]]} in attaches
      assert {"fx-many", {Fx.Handlers, :handle, 4}, [[:fx, :literal], [:fx, :two]]} in attaches
      assert {"fx-anon", {:anonymous, {Fx.Handlers, :attach, 0}}, [[:fx, :lazy]]} in attaches
      assert Enum.any?(r.sites, &(&1.kind == :detach and &1.handler.id == "fx-remote"))
    end

    test "Telemetry.Metrics definitions (string names and :event_name)", %{result: r} do
      metrics =
        for s <- r.sites,
            s.kind == :metric,
            do: {s.extra.metric_name, s.patterns, s.extra.measurement}

      assert {"fx.span.stop.duration", [[:fx, :span, :stop]], :duration} in metrics
      assert {"fx.literal.count", [[:fx, :literal]], :count} in metrics
      assert {"fx.custom.count", [[:fx, :literal]], :count} in metrics
    end
  end

  describe "catalog" do
    test "spans expand and group; sources and confidence", %{dir: dir} do
      cat = catalog([{:fx, dir}])
      assert %{start: true, stop: true, exception: true} = Catalog.spans(cat)[[:fx, :span]]

      e = Catalog.get(cat, [:fx, :literal])
      assert Event.confidence(e) == :literal
      assert MapSet.member?(e.sources, :handler_registration)
      assert MapSet.member?(e.sources, :metric_definition)
      assert Event.status(e) == :static_only

      assert Event.confidence(Catalog.get(cat, [:fx, :order, :created])) == :resolved
    end

    test "repeated discovery is idempotent", %{dir: dir} do
      result = scan([{:fx, dir}])
      once = TeleScope.Catalog.new() |> Catalog.add_static(result)
      twice = Catalog.add_static(once, result)
      assert once.events == twice.events
      assert once.patterns == twice.patterns
    end

    test "partial patterns are linked to matching concrete names", %{dir: dir} do
      cat = catalog([{:fx, dir}])
      entry = cat.patterns[[:fx, {:var, :unknown}, :start]]
      assert [:fx, :request, :start] in entry.matched
    end
  end

  describe "erlang modules" do
    test "Erlang telemetry calls are discovered" do
      dir = tmp_dir("erl")

      compile_erlang(
        """
        -module(fx_erl).
        -export([a/0, b/1]).
        a() -> telemetry:execute([fx_erl, tick], \#{n => 1}, \#{}).
        b(Name) -> telemetry:span([fx_erl, Name], \#{}, fun() -> {ok, \#{}} end).
        """,
        dir
      )

      r = scan([{:fx_erl, dir}])
      assert {:execute, "[:fx_erl, :tick]"} in emitted(r)
      assert {:span, "[:fx_erl, *]"} in emitted(r)
      site = Enum.find(r.sites, &(&1.function == {:a, 0}))
      assert site.file =~ ".erl" and site.line == 3
    end
  end

  describe "robustness (negative)" do
    test "modules without debug info are reported, not crashed on" do
      dir = tmp_dir("nodebug")

      compile_elixir(
        "defmodule Fx.NoDebug do\n def a, do: :telemetry.execute([:x], %{}, %{})\nend",
        dir,
        debug_info: false
      )

      compile_erlang(
        "-module(fx_erl_nodebug).\n-export([a/0]).\na() -> telemetry:execute([y], \#{}, \#{}).\n",
        dir,
        debug_info: false
      )

      assert {:error, :no_debug_info} = Beam.forms(Path.join(dir, "Elixir.Fx.NoDebug.beam"))
      r = scan([{:nodebug, dir}])
      assert Fx.NoDebug in r.no_debug_info
      assert :fx_erl_nodebug in r.no_debug_info
      assert r.sites == []

      diag = TeleScope.Diagnostics.run(catalog([{:nodebug, dir}]))
      assert Enum.any?(diag, &(&1.check == :no_debug_info and &1.severity == :warning))
    end

    test "invalid and truncated BEAM files are reported" do
      dir = tmp_dir("invalid")
      File.write!(Path.join(dir, "Elixir.Garbage.beam"), "not a beam file at all")

      [mod] =
        compile_elixir(
          "defmodule Fx.Truncated do\n def a, do: :telemetry.execute([:t], %{}, %{})\nend",
          dir
        )

      path = Path.join(dir, "#{mod}.beam")
      bin = File.read!(path)
      File.write!(path, binary_part(bin, 0, div(byte_size(bin), 2)))

      assert {:error, :invalid_beam} = Beam.forms(Path.join(dir, "Elixir.Garbage.beam"))
      # truncated: early chunks readable, debug info "missing" -> must be invalid, not stripped
      assert {:error, :invalid_beam} = Beam.forms(path)
      r = scan([{:bad, dir}])
      assert length(r.errors) == 2
      assert r.sites == []
    end

    test "missing directory and empty directory scan to nothing" do
      r = scan([{:none, "/nonexistent/ebin"}, {:empty, tmp_dir("empty")}])
      assert r.sites == [] and r.errors == [] and r.stats.beams == 0
    end

    test "modules defining related span events in different modules group together" do
      dir = tmp_dir("split_span")

      compile_elixir(
        """
        defmodule Fx.SplitA do
          def a, do: :telemetry.execute([:split, :op, :start], %{}, %{})
        end
        defmodule Fx.SplitB do
          def b, do: :telemetry.execute([:split, :op, :stop], %{duration: 1}, %{})
        end
        """,
        dir
      )

      cat = catalog([{:split, dir}])
      assert %{start: true, stop: true, exception: false} = Catalog.spans(cat)[[:split, :op]]
    end
  end
end
