defmodule Mix.Tasks.TelemetryTasksTest do
  @moduledoc """
  In-process tests of the mix tasks' argument handling. Invalid usage must
  exit with status 2 *before* compiling or scanning anything. End-to-end
  runs against a generated project are in test/integration/cli_test.exs.
  """
  use ExUnit.Case, async: false

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp usage_error(task, argv) do
    assert catch_exit(task.run(argv)) == {:shutdown, 2}
    assert_received {:mix_shell, :error, [message]}
    message
  end

  for task <- [Mix.Tasks.Telemetry.Check, Mix.Tasks.Telemetry.Explore] do
    @task task
    @name task |> Module.split() |> Enum.drop(2) |> Enum.map_join(".", &String.downcase/1)

    describe "mix #{@name}" do
      test "unknown option" do
        msg = usage_error(@task, ["--bogus"])
        assert msg =~ "#{@name}: unknown option --bogus"
        assert msg =~ "mix help #{@name}"
      end

      test "invalid option value" do
        assert usage_error(@task, ["--duration", "soon"]) =~
                 ~s(invalid value "soon" for --duration)
      end

      test "non-positive duration" do
        assert usage_error(@task, ["--runtime", "--duration", "0"]) =~
                 "--duration must be a positive number of milliseconds"
      end

      test "unknown format" do
        assert usage_error(@task, ["--format", "xml"]) =~
                 "unknown --format xml (expected console or json)"
      end

      test "unexpected positional argument" do
        assert usage_error(@task, ["my_app"]) =~ ~s(unexpected argument "my_app")
      end
    end
  end

  test "both tasks document their exit status" do
    for task <- [Mix.Tasks.Telemetry.Check, Mix.Tasks.Telemetry.Explore] do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(task)
      assert doc =~ "## Exit status"
      assert doc =~ "`2` - invalid usage"
    end
  end
end
