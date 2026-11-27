defmodule TeleScope.Integration.CLITest do
  @moduledoc """
  End-to-end tests of `mix telemetry.check` and `mix telemetry.explore`:
  a throwaway Mix project that depends on TeleScope by path is generated
  and the real `mix` executable is run against it. This verifies exit
  codes, strict mode, and that JSON written to stdout is parseable even
  when the project is recompiled first.

  Excluded by default (it compiles a project, ~10-30 s):

      mix test --include integration

  Needs no network: `:telemetry` is copied from this project's `deps/`.
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 300_000

  alias TeleScope.Test.JSONDecoder

  @root Path.expand("../..", __DIR__)

  @mix_exs """
  defmodule CliFixture.MixProject do
    use Mix.Project

    def project do
      [app: :cli_fixture, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
    end

    def application, do: [extra_applications: [:logger]]

    defp deps, do: [{:tele_scope, path: TELE_SCOPE_PATH}]
  end
  """

  @lib """
  defmodule CliFixture do
    # emitted: [:cli_fixture, :order, :created]
    def order_created(id),
      do: :telemetry.execute([:cli_fixture, :order, :created], %{count: 1}, %{id: id})

    # typo: nothing emits [:cli_fixture, :ordr, :created] -> TS002 warning
    def attach,
      do: :telemetry.attach("cli-fixture-typo", [:cli_fixture, :ordr, :created], &__MODULE__.handle/4, nil)

    def handle(_event, _measurements, _metadata, _config), do: :ok
  end
  """

  setup_all do
    dir =
      Path.join([
        System.tmp_dir!(),
        "tele_scope_test",
        "cli_#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "deps"))

    File.write!(
      Path.join(dir, "mix.exs"),
      String.replace(@mix_exs, "TELE_SCOPE_PATH", inspect(@root))
    )

    File.write!(Path.join([dir, "lib", "cli_fixture.ex"]), @lib)
    File.cp!(Path.join(@root, "mix.lock"), Path.join(dir, "mix.lock"))
    File.cp_r!(Path.join([@root, "deps", "telemetry"]), Path.join([dir, "deps", "telemetry"]))
    on_exit(fn -> File.rm_rf!(dir) end)

    {out, status} = mix(dir, ["compile"])
    assert status == 0, "fixture project failed to compile:\n#{out}"
    %{dir: dir}
  end

  # stderr is kept separate: stdout must contain nothing but the report
  defp mix(dir, args) do
    System.cmd(System.find_executable("mix"), args,
      cd: dir,
      env: [
        {"MIX_ENV", "dev"},
        {"MIX_BUILD_ROOT", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_DEPS_PATH", nil},
        {"MIX_LOCKFILE", nil},
        {"MIX_EXS", nil}
      ]
    )
  end

  defp touch_source(dir) do
    # forces the next task to recompile the project inside TeleScope's
    # quiet shell
    File.write!(Path.join([dir, "lib", "cli_fixture.ex"]), "\n# #{System.unique_integer()}\n", [
      :append
    ])
  end

  test "check passes by default and reports the warning with its code", %{dir: dir} do
    {out, status} = mix(dir, ["telemetry.check"])
    assert status == 0, out
    assert out =~ "[WARNING] TS002 Consumer references an event nothing emits"
    assert out =~ "Suggestion: Did you mean [:cli_fixture, :order, :created]?"
    assert out =~ "Result: PASSED"
  end

  test "--strict fails with exit status 1", %{dir: dir} do
    {out, status} = mix(dir, ["telemetry.check", "--strict"])
    assert status == 1, out
    assert out =~ "(fails check)"
    assert out =~ "Result: FAILED (strict: errors and warnings fail)"
  end

  test "--format json on stdout stays parseable when the project recompiles", %{dir: dir} do
    touch_source(dir)
    {out, status} = mix(dir, ["telemetry.check", "--strict", "--format", "json"])
    assert status == 1
    doc = JSONDecoder.decode!(out)
    assert %{"status" => "failed", "exit_code" => 1, "strict" => true} = doc
    assert Enum.any?(doc["diagnostics"], &(&1["code"] == "TS002" and &1["fails_check"]))
  end

  test "--output writes the JSON document to a file", %{dir: dir} do
    path = Path.join(dir, "check.json")
    {_out, status} = mix(dir, ["telemetry.check", "--format", "json", "--output", path])
    assert status == 0
    assert %{"status" => "passed", "exit_code" => 0} = JSONDecoder.decode!(File.read!(path))
  end

  test "explore --format json lists the project's events", %{dir: dir} do
    touch_source(dir)
    {out, status} = mix(dir, ["telemetry.explore", "--format", "json", "--app", "cli_fixture"])
    assert status == 0
    doc = JSONDecoder.decode!(out)
    ids = Enum.map(doc["events"], & &1["id"])
    assert "cli_fixture.order.created" in ids
    assert "cli_fixture.ordr.created" in ids
  end

  test "--runtime capture in a real VM", %{dir: dir} do
    path = Path.join(dir, "runtime.json")

    {_out, status} =
      mix(dir, [
        "telemetry.check",
        "--runtime",
        "--duration",
        "300",
        "--format",
        "json",
        "--output",
        path
      ])

    assert status == 0
    doc = JSONDecoder.decode!(File.read!(path))
    assert doc["runtime_captured"] == true
  end

  test "invalid usage exits with status 2", %{dir: dir} do
    assert {_out, 2} = mix(dir, ["telemetry.check", "--format", "xml"])
    assert {_out, 2} = mix(dir, ["telemetry.explore", "--nope"])
  end
end
