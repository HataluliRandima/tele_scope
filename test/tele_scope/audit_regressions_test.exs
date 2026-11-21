defmodule TeleScope.AuditRegressionsTest do
  @moduledoc """
  Regression tests for issues found in the pre-release audit
  (PRE_RELEASE_AUDIT.md). Each test names its finding id.
  """
  use ExUnit.Case, async: false
  @moduletag :tracing
  @compile {:no_warn_undefined, :trace}

  import TeleScope.Test.Fixtures
  alias TeleScope.Runtime.{Capture, Tracer}
  alias TeleScope.Discovery.Beam

  @legacy? Tracer.capabilities().default_backend == :legacy

  defp gate_bit_set?,
    do: Bitwise.band(:erlang.system_info(:trace_control_word), Tracer.gate_bit()) != 0

  describe "R1 concurrent tracers" do
    if @legacy? do
      test "a second legacy tracer is refused instead of silently going blind" do
        {:ok, t1} = Tracer.start(duration: 5_000)
        assert {:error, {:already_tracing, ^t1}} = Tracer.start(duration: 5_000)
        Tracer.stop(t1)
        {:ok, t2} = Tracer.start(duration: 5_000)
        Tracer.stop(t2)
      end
    else
      test "session tracers are independent: stopping one does not blind the other" do
        {:ok, t1} = Tracer.start(duration: 5_000)
        {:ok, t2} = Tracer.start(duration: 5_000)
        Tracer.stop(t1)
        :telemetry.execute([:audit, :r1], %{}, %{})
        Process.sleep(50)
        assert [:audit, :r1] in Enum.map(Tracer.stop(t2).names, & &1.name)
      end
    end
  end

  describe "R2 bounded mailbox under a burst of one new hot name" do
    test "default limits: gate engages, breaker does not trip, gate bit restored" do
      {:ok, t} = Tracer.start(duration: 10_000)
      parent = self()

      pids =
        for _ <- 1..System.schedulers_online() do
          spawn(fn ->
            receive do: (:go -> :ok)
            for _ <- 1..20_000, do: :telemetry.execute([:audit, :r2, :hot], %{}, %{})
            send(parent, :done)
          end)
        end

      Enum.each(pids, &send(&1, :go))
      for _ <- pids, do: assert_receive(:done, 30_000)
      res = Tracer.stop(t)

      assert res.status == :stopped, inspect(Map.drop(res, [:names]))
      assert res.peak_mailbox < 50_000
      assert [:audit, :r2, :hot] in Enum.map(res.names, & &1.name)
      refute gate_bit_set?()
    end

    test "gate bit is cleared when the tracer is killed while gated" do
      {:ok, t} = Tracer.start(duration: 10_000, gate_threshold: 1)

      flood =
        spawn(fn ->
          Stream.repeatedly(fn ->
            :telemetry.execute(
              [
                :audit,
                :r2,
                :kill,
                make_ref()
                |> :erlang.phash2()
                |> rem(50)
                |> Integer.to_string()
                |> String.to_atom()
              ],
              %{},
              %{}
            )
          end)
          |> Stream.run()
        end)

      Process.sleep(100)
      Process.exit(t, :kill)
      Process.exit(flood, :kill)
      Process.sleep(600)
      refute gate_bit_set?()

      if @legacy?,
        do: assert({:traced, false} = :erlang.trace_info({:telemetry, :execute, 3}, :traced))
    end

    test "the match spec honours the gate bit" do
      ms = Tracer.match_spec(%{})
      orig = :erlang.system_info(:trace_control_word)

      try do
        :erlang.system_flag(:trace_control_word, Bitwise.bor(orig, Tracer.gate_bit()))
        assert {:ok, false, _, _} = :erlang.match_spec_test([[:a], %{}, %{}], ms, :trace)

        :erlang.system_flag(
          :trace_control_word,
          Bitwise.band(orig, Bitwise.bnot(Tracer.gate_bit()))
        )

        assert {:ok, [:a], _, _} = :erlang.match_spec_test([[:a], %{}, %{}], ms, :trace)
      after
        :erlang.system_flag(:trace_control_word, orig)
      end
    end
  end

  describe "R3/R4 observer death during a capture" do
    test "capture survives, result is well formed, catalog merge works, diagnostic emitted" do
      {:ok, cap} = Capture.start(duration: 5_000, events: [[:audit, :r3]])
      Process.exit(:sys.get_state(cap).observer, :kill)
      # a tracer-discovered name now arrives while the observer is dead
      :telemetry.execute([:audit, :r4, :new], %{}, %{})
      Process.sleep(200)
      assert Process.alive?(cap)

      result = Capture.stop(cap)
      assert result.observations.status == :crashed
      assert result.observations.events == %{}

      cat = TeleScope.Catalog.add_capture(TeleScope.Catalog.new(), result)
      assert TeleScope.Catalog.get(cat, [:audit, :r4, :new]).observed

      assert Enum.any?(
               TeleScope.diagnose(cat),
               &(&1.check == :capture_limited and &1.message =~ "Observer crashed")
             )
    end

    test "invalid capture duration is rejected" do
      assert {:error, {:invalid_option, {:duration, :infinity}}} =
               Capture.start(duration: :infinity)

      assert {:error, {:invalid_option, {:duration, 0}}} = Capture.start(duration: 0)
    end

    test "capture durations at the tracer maximum are accepted" do
      {:ok, cap} = Capture.start(duration: 600_000, events: [])
      Capture.stop(cap)
    end
  end

  describe "R5-R7 static discovery" do
    test "R5 raise/throw branches do not add spurious dynamic alternatives" do
      dir = tmp_dir("audit_r5")

      compile_elixir(
        """
        defmodule Audit.R5 do
          def emit(kind) do
            event = case kind do
              :a -> [:r5, :a]
              :b -> [:r5, :b]
              _ -> raise ArgumentError, "bad"
            end
            :telemetry.execute(event, %{}, %{})
          end
          def emit2(k), do: :telemetry.execute(if(k, do: [:r5, :c], else: throw(:no)), %{}, %{})
        end
        """,
        dir
      )

      sites = scan([{:audit, dir}]).sites |> Enum.filter(&(&1.kind == :execute))

      assert Enum.find(sites, &(&1.function == {:emit, 1})).patterns |> Enum.sort() == [
               [:r5, :a],
               [:r5, :b]
             ]

      assert Enum.find(sites, &(&1.function == {:emit2, 1})).patterns == [[:r5, :c]]
    end

    test "R6 a debug_info backend named by an untrusted .beam is never called" do
      dir = tmp_dir("audit_r6")

      [mod] =
        compile_elixir(
          "defmodule Audit.R6 do\n def a, do: :telemetry.execute([:x], %{}, %{})\nend",
          dir
        )

      path = Path.join(dir, "#{mod}.beam")
      {:ok, _, chunks} = :beam_lib.all_chunks(to_charlist(path))
      evil = :erlang.term_to_binary({:debug_info_v1, __MODULE__.EvilBackend, :data})
      {:ok, bin} = :beam_lib.build_module(List.keyreplace(chunks, ~c"Dbgi", 0, {~c"Dbgi", evil}))
      File.write!(path, bin)

      assert {:error, {:untrusted_backend, __MODULE__.EvilBackend}} = Beam.forms(path)
      refute_received :evil_backend_called
    end

    test "R7 combinatorial name construction is bounded" do
      dir = tmp_dir("audit_r7")
      vars = for i <- 1..8, do: "s#{i}"

      body =
        Enum.map_join(vars, "\n", fn v ->
          "#{v} = case x do\n" <> Enum.map_join(1..10, "\n", &"  #{&1} -> :a#{&1}") <> "\nend"
        end)

      compile_elixir(
        "defmodule Audit.R7 do\n def f(x) do\n#{body}\n:telemetry.execute([#{Enum.join(vars, ", ")}], %{}, %{})\n end\nend",
        dir
      )

      {us, r} = :timer.tc(fn -> scan([{:audit, dir}]) end)
      assert [site] = Enum.filter(r.sites, &(&1.kind == :execute))
      assert site.patterns == [[{:splice, :unknown}]]
      # 10^8 lists would never finish; bounded evaluation is instant
      assert us < 5_000_000
    end
  end

  defmodule EvilBackend do
    def debug_info(_, _, _, _) do
      send(self(), :evil_backend_called)
      {:error, :evil}
    end
  end

  describe "sensitive key detection" do
    test "flags real secrets, not substrings of innocent words" do
      for k <-
            ~w(password api_key apiKey authorization password_hint oauth_token session_id client_secret credit_card_number)a,
          do: assert(TeleScope.Diagnostics.sensitive_key?(k), "#{k} should be sensitive")

      for k <-
            ~w(author_id passenger_count compass_heading bypass_cache tokenizer_ms classname session_count otp_app pinned)a,
          do: refute(TeleScope.Diagnostics.sensitive_key?(k), "#{k} should not be sensitive")
    end
  end
end
