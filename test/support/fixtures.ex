defmodule TeleScope.Test.Fixtures do
  @moduledoc """
  Compiles fixture modules to real `.beam` files so tests exercise the same
  code path as scanning `_build/*/ebin`.
  """

  alias TeleScope.Discovery.Scanner

  @doc "Unique temporary ebin directory."
  def tmp_dir(name) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "tele_scope_test",
        "#{name}_#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Compiles Elixir `source` into `dir`. Options: `debug_info: false`.
  Modules are also loaded (needed by runtime tests). Returns module list.
  """
  def compile_elixir(source, dir, opts \\ []) do
    debug = Keyword.get(opts, :debug_info, true)

    # Compiler options are global to the VM. Async test modules compile
    # fixtures concurrently, so without the lock one module's
    # `debug_info: false` leaks into another's compilation (fixtures silently
    # lose their debug info and static analysis finds nothing in them).
    modules =
      with_compiler_lock(fn ->
        previous = Code.get_compiler_option(:debug_info)
        ignore = Code.get_compiler_option(:ignore_module_conflict)

        try do
          Code.put_compiler_option(:debug_info, debug)
          Code.put_compiler_option(:ignore_module_conflict, true)

          {modules, _diagnostics} =
            Code.with_diagnostics(fn -> Code.compile_string(source, "fixture.ex") end)

          modules
        after
          Code.put_compiler_option(:debug_info, previous)
          Code.put_compiler_option(:ignore_module_conflict, ignore)
        end
      end)

    for {mod, bin} <- modules do
      File.write!(Path.join(dir, "#{mod}.beam"), bin)
      mod
    end
  end

  # Local lock only: [node()] keeps peer nodes out of it.
  defp with_compiler_lock(fun) do
    :global.trans({__MODULE__.CompilerLock, self()}, fun, [node()])
  end

  @doc "Compiles Erlang `source` (one module) into `dir`."
  def compile_erlang(source, dir, opts \\ []) do
    erl = Path.join(dir, "fixture_#{System.unique_integer([:positive])}.erl")
    File.write!(erl, source)

    copts =
      [:binary, :return_errors] ++
        if(Keyword.get(opts, :debug_info, true), do: [:debug_info], else: [])

    {:ok, mod, bin} = :compile.file(to_charlist(erl), copts)
    File.rm!(erl)
    File.write!(Path.join(dir, "#{mod}.beam"), bin)
    {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", bin)
    mod
  end

  @doc "Static scan of the given dirs as `{app, dir}`."
  def scan(app_dirs, opts \\ []) do
    Scanner.scan(
      app_dirs,
      Keyword.put_new(opts, :rules, TeleScope.Discovery.Rule.default_rules())
    )
  end

  @doc "Full static catalog of fixture dirs (no config)."
  def catalog(app_dirs, opts \\ []) do
    TeleScope.scan(
      Keyword.merge(
        [
          app_dirs: app_dirs,
          get_env: fn _ -> [] end,
          # fixture apps are the "project" unless a test says otherwise
          project_apps: Enum.map(app_dirs, &elem(&1, 0))
        ],
        opts
      )
    )
  end

  @doc "Patterns of emitting call sites, formatted, for compact assertions."
  def emitted(result) do
    for s <- result.sites,
        s.kind in [:execute, :execute_lazy, :span],
        p <- s.patterns,
        uniq: true do
      {s.kind, TeleScope.EventName.format(p)}
    end
    |> Enum.sort()
  end
end
