defmodule TeleScope.ReportersTest do
  @moduledoc "Console and JSON output of reports and checks."
  use ExUnit.Case, async: true

  import TeleScope.Test.Fixtures
  alias TeleScope.{Catalog, Diagnostics}
  alias TeleScope.Reporters.{Console, JSON}
  alias TeleScope.Test.{JSONDecoder, Synthetic}

  @source """
  defmodule TsRep.App do
    def created, do: :telemetry.execute([:ts_rep, :order, :created], %{total: 1}, %{})
    def attach, do: :telemetry.attach("ts-rep-typo", [:ts_rep, :ordr, :created], &__MODULE__.h/4, nil)
    def h(_, _, _, _), do: :ok
  end
  """

  setup_all do
    dir = tmp_dir("ts_rep")
    compile_elixir(@source, dir)
    # a second app, to exercise --app filtering
    other = tmp_dir("ts_rep_other")

    compile_elixir(
      "defmodule TsRep.Other do\n def x, do: :telemetry.execute([:ts_rep_other, :x], %{}, %{})\nend",
      other
    )

    catalog = catalog([{:ts_rep, dir}, {:ts_rep_other, other}, {:ghost, "/nonexistent/ebin"}])
    %{catalog: catalog, diags: Diagnostics.run(catalog)}
  end

  describe "Console.render_check/3" do
    test "one block per visible diagnostic with code, event, problem, location, suggestion",
         %{catalog: catalog, diags: diags} do
      out =
        Console.render_check(diags, Diagnostics.evaluate(diags, strict: true), catalog: catalog)

      assert out =~ ~r/^TeleScope: \d+ events from 2 modules/
      assert out =~ "[WARNING] TS002 Consumer references an event nothing emits (fails check)"
      assert out =~ "  Event:      [:ts_rep, :ordr, :created]"

      assert out =~
               "  Problem:    [:ts_rep, :ordr, :created] is consumed by handler \"ts-rep-typo\""

      assert out =~ ~r/  Location:   .*fixture\.ex:\d+/
      assert out =~ "  Suggestion: Did you mean [:ts_rep, :order, :created]?"
      assert out =~ "Result: FAILED (strict: errors and warnings fail): 0 errors, 1 warning,"
    end

    test "limitations are always shown and never marked as failing", %{diags: diags} do
      out = Console.render_check(diags, Diagnostics.evaluate(diags, strict: true))
      assert out =~ "[INFO] TS012 Part of the build could not be scanned (limitation)\n"
      assert out =~ "/nonexistent/ebin"
    end

    test "other info diagnostics are hidden unless verbose" do
      diags =
        catalog([])
        |> Catalog.add_capture(Synthetic.capture(events: %{[:ts_rep, :lonely] => []}))
        |> Diagnostics.run()

      # observed with no handler (TS010) and not predicted statically (TS013)
      assert [%{code: "TS010"}, %{code: "TS013"}] = diags
      quiet = Console.render_check(diags, Diagnostics.evaluate(diags))
      refute quiet =~ "TS010"

      assert quiet =~
               "Result: PASSED (errors fail): 0 errors, 0 warnings, 2 info (2 hidden; use --verbose)"

      verbose = Console.render_check(diags, Diagnostics.evaluate(diags), verbose: true)
      assert verbose =~ "[INFO] TS010 Event has no handler attached\n"
      refute verbose =~ "hidden"
    end

    test "passing check output", %{diags: diags} do
      out = Console.render_check(diags, Diagnostics.evaluate(diags))
      assert out =~ "Result: PASSED (errors fail)"
      refute out =~ "fails check"
    end
  end

  describe "JSON check document" do
    test "parses, carries status, exit code, counts and every diagnostic",
         %{catalog: catalog, diags: diags} do
      verdict = Diagnostics.evaluate(diags, strict: true)
      doc = JSONDecoder.decode!(JSON.render_check(catalog, diags, verdict))

      assert %{
               "schema_version" => 1,
               "status" => "failed",
               "strict" => true,
               "exit_code" => 1,
               "runtime_captured" => false,
               "counts" => %{"error" => 0, "warning" => 1, "info" => info}
             } = doc

      assert length(doc["diagnostics"]) == 1 + info
      ts002 = Enum.find(doc["diagnostics"], &(&1["code"] == "TS002"))

      assert %{
               "check" => "consumer_without_emitter",
               "severity" => "warning",
               "limitation" => false,
               "fails_check" => true,
               "event" => ["ts_rep", "ordr", "created"],
               "locations" => [_],
               "detail" => %{"similar" => [["ts_rep", "order", "created"]]}
             } = ts002

      assert Enum.all?(doc["diagnostics"] -- [ts002], &(&1["fails_check"] == false))
    end

    test "non-strict check passes with exit code 0", %{catalog: catalog, diags: diags} do
      doc = JSONDecoder.decode!(JSON.render_check(catalog, diags, Diagnostics.evaluate(diags)))
      assert %{"status" => "passed", "exit_code" => 0} = doc
    end
  end

  describe "full reports" do
    test "JSON report parses and honours the apps filter", %{catalog: catalog} do
      all = JSONDecoder.decode!(TeleScope.report(catalog, format: :json))
      ids = Enum.map(all["events"], & &1["id"])
      assert "ts_rep.order.created" in ids and "ts_rep_other.x" in ids

      only = JSONDecoder.decode!(TeleScope.report(catalog, format: :json, apps: [:ts_rep_other]))
      ids = Enum.map(only["events"], & &1["id"])
      assert "ts_rep_other.x" in ids
      refute "ts_rep.order.created" in ids
      # referenced-only events have no app and are always kept
      assert "ts_rep.ordr.created" in ids
      assert only["filter"] == %{"apps" => ["ts_rep_other"]}
    end

    test "JSON report with runtime data and metric suggestions parses", %{catalog: catalog} do
      cat =
        Catalog.add_capture(
          catalog,
          Synthetic.capture(
            events: %{
              [:ts_rep, :order, :created] => [
                measurements: %{total: :integer},
                metadata: %{"string key": :binary}
              ]
            },
            trace_names: [[:ts_rep, :runtime, :only]]
          )
        )

      metrics = TeleScope.recommend_metrics(cat)
      doc = JSONDecoder.decode!(TeleScope.report(cat, format: :json, metrics: metrics))
      event = Enum.find(doc["events"], &(&1["id"] == "ts_rep.order.created"))
      assert event["status"] == "observed"
      assert event["measurements"]["total"]["types"] == %{"integer" => 1}
      assert is_list(doc["metric_suggestions"])
    end

    test "console report shows diagnostic codes and limitations", %{catalog: catalog} do
      out = TeleScope.report(catalog)
      assert out =~ "[warning] TS002 consumer_without_emitter:"
      assert out =~ "[info] TS012 scan_error (limitation):"
    end

    test "unknown format is an ArgumentError", %{catalog: catalog} do
      assert_raise ArgumentError, ~r/unknown report format :xml/, fn ->
        TeleScope.report(catalog, format: :xml)
      end
    end
  end
end
