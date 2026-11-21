# Tracing tests manipulate VM-global state: they are async: false and tagged.
ExUnit.start(exclude: [:peer, :bench])
Logger.configure(level: :warning)
