# Tracing tests manipulate VM-global state: they are async: false and tagged.
ExUnit.start(exclude: [:peer, :bench, :integration])
Logger.configure(level: :warning)
