IO.puts("OTP #{System.otp_release()} / Elixir #{System.version()} / erts #{:erlang.system_info(:version)}")
IO.puts("trace module available: #{Code.ensure_loaded?(:trace)}")
if Code.ensure_loaded?(:trace), do: IO.inspect(:trace.module_info(:exports) |> Enum.filter(fn {n,_} -> n in [:session_create, :session_destroy, :function, :process, :session_info] end))
