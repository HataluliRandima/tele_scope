defmodule TeleScope.Runtime.HandlersTest do
  use ExUnit.Case, async: false
  @compile {:no_warn_undefined, :trace}
  alias TeleScope.Runtime.Handlers

  defmodule H do
    def handle(_, _, _, _), do: :ok
    def closure(x), do: fn _, _, _, _ -> x end
  end

  setup do
    ids = ["h-ext", "h-many", "h-anon", "h-closure"]
    on_exit(fn -> Enum.each(ids, &:telemetry.detach/1) end)
    :ok
  end

  test "global enumeration via list_handlers([]) including attach_many expansion" do
    :telemetry.attach("h-ext", [:h, :a], &H.handle/4, %{password: "x"})
    :telemetry.attach_many("h-many", [[:h, :a], [:h, :b]], &H.handle/4, nil)
    list = Handlers.list()
    assert Enum.count(list, &(&1.id == "h-many")) == 2
    ext = Enum.find(list, &(&1.id == "h-ext"))
    assert ext.function.mfa == {H, :handle, 4}
    # config is never copied, only its type
    assert ext.config_type == :map
    refute inspect(list) =~ "password"
    assert Map.keys(Handlers.by_event(list)) |> Enum.member?([:h, :b])
  end

  test "anonymous closures resolve to their underlying local function arity" do
    :telemetry.attach("h-closure", [:h, :c], H.closure(1), nil)
    h = Enum.find(Handlers.list(), &(&1.id == "h-closure"))
    assert h.function.type == :local
    {H, name, 5} = h.function.mfa
    assert Atom.to_string(name) =~ "closure"
  end

  test "TeleScope's own observer handlers are excluded" do
    {:ok, obs} = TeleScope.Runtime.Observer.start(events: [[:h, :own]])
    refute Enum.any?(Handlers.list(), &match?({{TeleScope.Runtime.Observer, _}, _}, &1.id))
    TeleScope.Runtime.Observer.stop(obs)
  end

  test "invocation counting with call_count, including handlers attached later" do
    :telemetry.attach("h-ext", [:h, :a], &H.handle/4, nil)
    tracker = Handlers.track(Handlers.list())
    :telemetry.attach("h-anon", [:h, :x], fn _, _, _, _ -> :ok end, nil)
    tracker = Handlers.track_more(tracker, Handlers.list())

    for _ <- 1..3, do: :telemetry.execute([:h, :a], %{}, %{})
    :telemetry.execute([:h, :x], %{}, %{})
    counts = Handlers.invocation_counts(tracker)
    Handlers.stop_tracking(tracker)

    assert counts[{H, :handle, 4}] == 3
    anon = Enum.find(Handlers.list(), &(&1.id == "h-anon")).function.mfa
    assert counts[anon] == 1
  end

  test "invocation tracking is removed when its owner is killed" do
    :telemetry.attach("h-ext", [:h, :a], &H.handle/4, nil)
    parent = self()

    # only plain data leaves the owner: an OTP 27+ session stays alive while
    # any process holds its handle
    owner =
      spawn(fn ->
        t = Handlers.track(Handlers.list())
        send(parent, {:tracker, %{backend: t.backend, mfas: t.mfas}})
        receive do: (:never -> :ok)
      end)

    assert_receive {:tracker, tracker}
    assert {H, :handle, 4} in tracker.mfas
    Process.exit(owner, :kill)
    Process.sleep(100)
    :erlang.garbage_collect()

    case tracker.backend do
      :legacy ->
        assert {:call_count, false} = :erlang.trace_info({H, :handle, 4}, :call_count)

      :session ->
        refute Enum.any?(:trace.session_info(:all), &match?({:tele_scope_handlers, _}, &1))
    end
  end

  test "shared handler functions are detected" do
    :telemetry.attach("h-ext", [:h, :a], &H.handle/4, nil)
    :telemetry.attach("h-many", [:h, :b], &H.handle/4, nil)
    assert %{{H, :handle, 4} => ids} = Handlers.shared_functions(Handlers.list())
    assert Enum.sort(ids) == ["h-ext", "h-many"]
  end

  test "detached handlers disappear" do
    :telemetry.attach("h-ext", [:h, :a], &H.handle/4, nil)
    :telemetry.detach("h-ext")
    refute Enum.any?(Handlers.list(), &(&1.id == "h-ext"))
  end
end
