defmodule TeleScope.DiagnosticsTest do
  @moduledoc """
  Diagnostics: stable codes, required fields, determinism, strict-mode
  evaluation and each check's evidence rules. Runtime evidence comes from
  synthetic capture results (TeleScope.Test.Synthetic), so no handlers are
  attached and no tracing happens: these tests are async.
  """
  use ExUnit.Case, async: true

  import TeleScope.Test.Fixtures
  alias TeleScope.{Catalog, Diagnostics}
  alias TeleScope.Test.Synthetic

  @source """
  defmodule TsDiag.App do
    def processed(ms), do: :telemetry.execute([:ts_diag, :orders, :processed], %{duration: ms}, %{})
    def start, do: :telemetry.execute([:ts_diag, :job, :start], %{}, %{})
    def dynamic(x), do: :telemetry.execute([:ts_diag, :dyn, x], %{}, %{})
  end

  defmodule TsDiag.Telemetry do
    def metrics do
      [
        Telemetry.Metrics.summary("ts_diag.orders.processed.duration_ms"),
        Telemetry.Metrics.counter("ts_diag.ordrs.processed.count")
      ]
    end

    def attach do
      :telemetry.attach("ts-diag-handler", [:ts_diag, :orders, :processed], &__MODULE__.handle/4, nil)
    end

    def handle(_, _, _, _), do: :ok
  end
  """

  setup_all do
    dir = tmp_dir("ts_diag")
    compile_elixir(@source, dir)
    %{dir: dir, static: catalog([{:ts_diag, dir}])}
  end

  defp codes(diags), do: Enum.map(diags, &{&1.code, &1.severity, &1.event})
  defp with_code(diags, code), do: Enum.filter(diags, &(&1.code == code))

  describe "definitions" do
    test "codes are unique, well-formed and map 1:1 to checks" do
      defs = Diagnostics.definitions()
      assert defs |> Enum.map(& &1.code) |> Enum.uniq() |> length() == length(defs)
      assert defs |> Enum.map(& &1.check) |> Enum.uniq() |> length() == length(defs)

      for d <- defs do
        assert d.code =~ ~r/^TS\d{3}$/
        assert d.severities != [] and Enum.all?(d.severities, &(&1 in [:error, :warning, :info]))
        assert Diagnostics.definition(d.code) == d
        assert Diagnostics.definition(d.check) == d
      end
    end

    test "codes are stable (renumbering is a breaking change)" do
      assert Enum.map(Diagnostics.definitions(), &{&1.code, &1.check}) == [
               {"TS001", :handler_failure},
               {"TS002", :consumer_without_emitter},
               {"TS003", :metric_measurement_missing},
               {"TS004", :inactive_handler},
               {"TS005", :sensitive_key},
               {"TS006", :no_debug_info},
               {"TS007", :incomplete_span},
               {"TS008", :unresolved_call_site},
               {"TS009", :schema_drift},
               {"TS010", :no_runtime_handler},
               {"TS011", :capture_limited},
               {"TS012", :scan_error},
               {"TS013", :runtime_only_event}
             ]
    end

    test "every code is documented in DIAGNOSTICS.md" do
      doc = File.read!(Path.expand("../../DIAGNOSTICS.md", __DIR__))

      for d <- Diagnostics.definitions() do
        assert doc =~ "## #{d.code} ", "#{d.code} is missing from DIAGNOSTICS.md"
        assert doc =~ "`#{d.check}`"
      end
    end
  end

  describe "diagnostic contract" do
    test "every diagnostic has the documented fields and a severity allowed by its definition",
         %{static: static} do
      cat =
        Catalog.add_capture(
          static,
          Synthetic.capture(
            events: %{
              [:ts_diag, :orders, :processed] => [
                measurements: %{duration: :integer},
                metadata: %{password: :binary}
              ]
            },
            trace_names: [[:ts_diag, :dyn, :x]],
            handler_failures: [
              %{
                handler_id: "ts-diag-handler",
                event: [:ts_diag, :orders, :processed],
                count: 1,
                kind: :error
              }
            ]
          )
        )

      diags = Diagnostics.run(cat)
      assert length(diags) > 5

      for d <- diags do
        assert %{
                 code: code,
                 check: check,
                 severity: severity,
                 limitation: limitation,
                 title: title,
                 message: message,
                 suggestion: suggestion,
                 locations: locations,
                 detail: detail
               } = d

        definition = Diagnostics.definition(code)
        assert definition.check == check
        assert definition.title == title
        assert severity in definition.severities
        assert is_boolean(limitation) and (not limitation or severity == :info)
        assert is_binary(message) and message != ""
        assert suggestion == nil or is_binary(suggestion)
        assert is_list(locations) and Enum.all?(locations, &is_binary/1)
        assert is_map(detail)
      end
    end

    test "results are deterministic across runs and rescans", %{dir: dir, static: static} do
      a = Diagnostics.run(static)
      assert a == Diagnostics.run(static)
      assert a == Diagnostics.run(catalog([{:ts_diag, dir}]))
    end

    test "sorted by severity, then code" do
      cat =
        Catalog.add_capture(
          catalog([]),
          Synthetic.capture(
            events: %{[:a] => [metadata: %{token: :binary, x: :integer}], [:b] => []},
            handler_failures: [%{handler_id: "h", event: [:a], count: 1, kind: :error}]
          )
        )

      diags = Diagnostics.run(cat)

      ranks =
        Enum.map(diags, &{Map.fetch!(%{error: 0, warning: 1, info: 2}, &1.severity), &1.code})

      assert ranks == Enum.sort(ranks)
      assert hd(diags).code == "TS001"
    end
  end

  describe "evaluate/2 (strict mode)" do
    defp diag(severity, limitation \\ false),
      do: %{severity: severity, limitation: limitation, code: "TS999"}

    test "errors always fail; warnings only in strict mode" do
      assert %{status: :passed} = Diagnostics.evaluate([diag(:warning), diag(:info)])
      assert %{status: :failed} = Diagnostics.evaluate([diag(:warning)], strict: true)
      assert %{status: :failed} = Diagnostics.evaluate([diag(:error)])

      assert %{status: :passed, counts: %{error: 0, warning: 0, info: 0}} =
               Diagnostics.evaluate([])
    end

    test "limitations never fail a check, even in strict mode" do
      assert %{status: :passed, failing: []} =
               Diagnostics.evaluate([diag(:info, true), diag(:info)], strict: true)
    end

    test "failing lists exactly the diagnostics that fail" do
      w = diag(:warning)
      e = diag(:error)
      assert %{failing: [^e]} = Diagnostics.evaluate([w, e, diag(:info)])
      assert %{failing: [^w, ^e]} = Diagnostics.evaluate([w, e, diag(:info)], strict: true)
    end
  end

  describe "TS002 consumer_without_emitter" do
    test "static typo in a metric: warning with location and a suggestion", %{static: static} do
      [d] = Diagnostics.run(static) |> with_code("TS002")
      assert d.severity == :warning
      assert d.event == [:ts_diag, :ordrs, :processed]
      assert d.message =~ "metric ts_diag.ordrs.processed.count"
      assert [location] = d.locations
      assert location =~ "fixture.ex:"
      assert d.suggestion =~ "Did you mean [:ts_diag, :orders, :processed]?"
    end

    test "the same consumer in a dependency is info", %{dir: dir} do
      cat = catalog([{:ts_diag, dir}], project_apps: [:some_other_app])
      [d] = Diagnostics.run(cat) |> with_code("TS002")
      assert d.severity == :info
      assert d.suggestion == nil
    end
  end

  describe "TS003 metric_measurement_missing" do
    test "suggests the observed measurement closest to the metric's", %{static: static} do
      cat =
        Catalog.add_capture(
          static,
          Synthetic.capture(
            events: %{[:ts_diag, :orders, :processed] => [measurements: %{duration: :integer}]}
          )
        )

      [d] = Diagnostics.run(cat) |> with_code("TS003")
      assert d.severity == :warning
      assert d.message =~ "reads measurement :duration_ms"
      assert d.message =~ "(seen: :duration)"
      assert d.suggestion =~ "Did you mean :duration?"
      assert d.detail.similar == [:duration]
      assert [_] = d.locations
    end

    test "static-only catalogs never produce it", %{static: static} do
      assert Diagnostics.run(static) |> with_code("TS003") == []
    end
  end

  describe "TS004 inactive_handler" do
    @event [:ts_diag, :orders, :processed]
    @mfa {TsDiag.Telemetry, :handle, 4}

    defp inactive(static, tracked_at, last_seen_at) do
      cat =
        Catalog.add_capture(
          static,
          Synthetic.capture(
            events: %{@event => [measurements: %{duration: :integer}, last_seen_at: last_seen_at]},
            handlers: [
              %{
                id: "ts-diag-handler",
                event_name: @event,
                mfa: @mfa,
                invocations: 0,
                tracked_at: tracked_at
              }
            ]
          )
        )

      Diagnostics.run(cat) |> with_code("TS004")
    end

    test "warning when the event fired after counting for the handler started", %{static: static} do
      t = Synthetic.t0()
      assert [%{severity: :warning, locations: [loc]}] = inactive(static, t + 100, t + 200)
      assert loc =~ "fixture.ex:"
    end

    test "only info when the handler was picked up after the event last fired (no false warning)",
         %{static: static} do
      t = Synthetic.t0()
      assert [%{severity: :info, message: msg}] = inactive(static, t + 300, t + 200)
      assert msg =~ "not after counting for this handler started"
      # same millisecond: ambiguous, never a warning
      assert [%{severity: :info}] = inactive(static, t + 200, t + 200)
    end
  end

  describe "TS005 sensitive_key" do
    test "flags secret-looking keys with emitter locations", %{static: static} do
      cat =
        Catalog.add_capture(
          static,
          Synthetic.capture(
            events: %{
              [:ts_diag, :orders, :processed] => [
                measurements: %{duration: :integer},
                metadata: %{api_key: :binary, author_id: :integer}
              ]
            }
          )
        )

      assert [d] = Diagnostics.run(cat) |> with_code("TS005")
      assert d.detail.key == :api_key
      assert [loc] = d.locations
      assert loc =~ "fixture.ex:"
    end
  end

  describe "TS006 no_debug_info" do
    setup do
      dir = tmp_dir("ts_diag_nodebug")

      compile_elixir(
        "defmodule TsDiag.NoDebug do\n def a, do: :telemetry.execute([:ts_diag, :nd], %{}, %{})\nend",
        dir,
        debug_info: false
      )

      %{nodebug: dir}
    end

    test "warning for the project's own modules", %{nodebug: dir} do
      assert [%{severity: :warning, limitation: false, suggestion: s}] =
               catalog([{:nd_app, dir}]) |> Diagnostics.run() |> with_code("TS006")

      assert s =~ "debug_info"
    end

    test "info limitation for dependencies: never fails --strict", %{nodebug: dir} do
      diags = catalog([{:nd_app, dir}], project_apps: [:other]) |> Diagnostics.run()
      assert [%{severity: :info, limitation: true}] = with_code(diags, "TS006")
      assert %{status: :passed} = Diagnostics.evaluate(diags, strict: true)
    end
  end

  describe "TS007 / TS008 static structure" do
    test "a lone :start event and an unresolvable name", %{static: static} do
      diags = Diagnostics.run(static)
      assert [%{event: [:ts_diag, :job], locations: [_]}] = with_code(diags, "TS007")
      assert [%{detail: %{pattern: "[:ts_diag, :dyn, *]"}}] = with_code(diags, "TS008")
    end
  end

  describe "TS011 capture_limited" do
    test "a tracer that could not start is a limitation with a remedy" do
      cat =
        Catalog.add_capture(
          catalog([]),
          Synthetic.capture(trace: nil, trace_error: {:already_tracing, self()})
        )

      assert [d] = Diagnostics.run(cat) |> with_code("TS011")
      assert d.limitation and d.severity == :info
      assert d.message =~ "another TeleScope tracer"
      assert d.suggestion =~ "OTP 27"
    end

    test "observer limits and tracer pauses are reported" do
      cat =
        Catalog.add_capture(
          catalog([]),
          Synthetic.capture(
            trace: %{
              status: :completed,
              backend: :session,
              names: [],
              gate_closures: 2,
              gated_ms: 40
            },
            observer: [dropped_events: 10]
          )
        )

      messages = Diagnostics.run(cat) |> with_code("TS011") |> Enum.map(& &1.message)
      assert Enum.any?(messages, &(&1 =~ "paused discovery 2 time(s)"))
      assert Enum.any?(messages, &(&1 =~ "10 event(s) were counted but not shape-recorded"))
    end
  end

  describe "TS012 scan_error" do
    defmodule FailingRule do
      @behaviour TeleScope.Discovery.Rule
      def config_events(_ctx), do: throw(:broken)
    end

    test "missing directories, unreadable beams and failing rules are surfaced as limitations" do
      bad = tmp_dir("ts_diag_bad")
      File.write!(Path.join(bad, "Elixir.TsDiag.Garbage.beam"), "garbage")

      diags =
        catalog([{:ghost, "/nonexistent/ts_diag/ebin"}, {:bad, bad}],
          rules: [FailingRule]
        )
        |> Diagnostics.run()
        |> with_code("TS012")

      assert Enum.all?(diags, &(&1.limitation and &1.severity == :info))
      messages = Enum.map_join(diags, "\n", & &1.message)
      assert messages =~ "/nonexistent/ts_diag/ebin"
      assert messages =~ "Elixir.TsDiag.Garbage.beam"
      assert messages =~ "FailingRule failed"
    end
  end

  describe "TS013 runtime_only_event" do
    test "names discovered only at runtime are linked to the call site that matches them",
         %{static: static} do
      cat = Catalog.add_capture(static, Synthetic.capture(trace_names: [[:ts_diag, :dyn, :x]]))
      assert [d] = Diagnostics.run(cat) |> with_code("TS013")
      assert d.event == [:ts_diag, :dyn, :x]
      assert d.message =~ "only knew it as [:ts_diag, :dyn, *]"
      assert [_] = d.locations
      # and TS008 disappears: the pattern is now explained
      assert Diagnostics.run(cat) |> with_code("TS008") == []
    end

    test "names nothing predicted" do
      cat = Catalog.add_capture(catalog([]), Synthetic.capture(trace_names: [[:nowhere, :x]]))
      assert [d] = Diagnostics.run(cat) |> with_code("TS013")
      assert d.message =~ "no scanned call site"
    end
  end

  test "TS001 handler_failure is an error that fails every check", %{static: static} do
    cat =
      Catalog.add_capture(
        static,
        Synthetic.capture(
          events: %{[:ts_diag, :orders, :processed] => [measurements: %{duration: :integer}]},
          handler_failures: [
            %{
              handler_id: "ts-diag-handler",
              event: [:ts_diag, :orders, :processed],
              count: 3,
              kind: :error
            }
          ]
        )
      )

    diags = Diagnostics.run(cat)
    assert [d] = with_code(diags, "TS001")
    assert d.severity == :error
    assert d.message =~ "3 time(s)"
    # static registration of the same handler id gives the location
    assert [loc] = d.locations
    assert loc =~ "fixture.ex:"
    assert %{status: :failed} = Diagnostics.evaluate(diags)
    assert {"TS001", :error, [:ts_diag, :orders, :processed]} in codes(diags)
  end
end
