defmodule TeleScope.Discovery.Beam do
  @moduledoc """
  Low-level access to compiled `.beam` files.

  Two different levels of information are read:

    * cheap chunks that are always present (`:imports`, `:attributes`) - used
      to decide whether a module is worth decoding at all;
    * the `debug_info` chunk, converted to Erlang abstract forms via the
      `:debug_info_v1` backend (`:elixir_erl` for Elixir, `:erl_abstract_code`
      for Erlang). This is expensive and may be missing (stripped releases,
      `debug_info: false`, some Erlang builds).

  Every function returns tagged tuples; nothing in here raises on bad input.
  """

  @type load_error ::
          :no_debug_info
          | :invalid_beam
          | {:file_error, term()}
          | {:debug_info_error, term()}
          | {:backend_unavailable, module()}
          | {:untrusted_backend, atom()}

  @doc """
  Reads the external call table of a module. Returns `{:ok, module, imports}`
  where imports is a list of `{m, f, a}`.
  """
  @spec imports(Path.t()) :: {:ok, module(), [mfa()]} | {:error, load_error()}
  def imports(path) do
    case safe_chunks(path, [:imports]) do
      {:ok, {module, [imports: imports]}} -> {:ok, module, imports}
      {:error, _} = error -> error
    end
  end

  @doc """
  Reads persisted attributes (no debug info required). Used for
  `telemetry_registry`-style `telemetry_event` declarations.
  """
  @spec attributes(Path.t()) :: {:ok, module(), keyword()} | {:error, load_error()}
  def attributes(path) do
    case safe_chunks(path, [:attributes]) do
      {:ok, {module, [attributes: attrs]}} -> {:ok, module, attrs}
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns the module's Erlang abstract forms.

  Tries, in order:
    1. `debug_info` chunk with the `:debug_info_v1` backend (`:erlang_v1` format)
    2. legacy `abstract_code` chunk (`:raw_abstract_v1`)
  """
  @spec forms(Path.t()) :: {:ok, module(), [tuple()]} | {:error, load_error()}
  def forms(path) do
    case safe_chunks(path, [:debug_info]) do
      {:ok, {module, [debug_info: {:debug_info_v1, _backend, :none}]}} ->
        _ = module
        legacy_abstract_code(path)

      {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} ->
        from_backend(module, backend, data)

      {:ok, {_module, [debug_info: _other]}} ->
        legacy_abstract_code(path)

      {:error, :missing_chunk} ->
        legacy_abstract_code(path)

      {:error, _} = error ->
        error
    end
  end

  # The backend module is named *inside* the .beam file. Calling an
  # arbitrary module named by an untrusted file is unacceptable (audit R6),
  # so only the backends shipped by Erlang/OTP and Elixir are used. Others
  # can be enabled explicitly: config :tele_scope, debug_info_backends: [...]
  @default_backends [:elixir_erl, :erl_abstract_code]

  defp from_backend(module, backend, data) do
    allowed = @default_backends ++ Application.get_env(:tele_scope, :debug_info_backends, [])

    cond do
      backend not in allowed ->
        {:error, {:untrusted_backend, backend}}

      Code.ensure_loaded?(backend) and function_exported?(backend, :debug_info, 4) ->
        call_backend(module, backend, data)

      true ->
        {:error, {:backend_unavailable, backend}}
    end
  end

  defp call_backend(module, backend, data) do
    case backend.debug_info(:erlang_v1, module, data, []) do
      {:ok, forms} -> {:ok, module, forms}
      # e.g. Erlang modules compiled without +debug_info carry
      # {debug_info_v1, erl_abstract_code, {none, Opts}}
      {:error, :missing} -> {:error, :no_debug_info}
      {:error, reason} -> {:error, {:debug_info_error, reason}}
    end
  rescue
    e -> {:error, {:debug_info_error, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:debug_info_error, {kind, reason}}}
  end

  defp legacy_abstract_code(path) do
    case safe_chunks(path, [:abstract_code]) do
      {:ok, {module, [abstract_code: {:raw_abstract_v1, forms}]}} -> {:ok, module, forms}
      {:ok, {_module, [abstract_code: :no_abstract_code]}} -> no_debug_info_or_corrupt(path)
      {:ok, _} -> no_debug_info_or_corrupt(path)
      {:error, :missing_chunk} -> no_debug_info_or_corrupt(path)
      {:error, _} = error -> error
    end
  end

  # beam_lib reads chunks lazily: a truncated file can still yield its early
  # chunks (imports, attributes) and only "miss" debug info. Distinguish a
  # genuinely stripped module from a corrupt file.
  defp no_debug_info_or_corrupt(path) do
    case :beam_lib.all_chunks(to_charlist(path)) do
      {:ok, _, _} -> {:error, :no_debug_info}
      _ -> {:error, :invalid_beam}
    end
  rescue
    _ -> {:error, :invalid_beam}
  end

  defp safe_chunks(path, chunks) do
    charlist = to_charlist(path)

    try do
      case :beam_lib.chunks(charlist, chunks) do
        {:ok, result} ->
          {:ok, result}

        {:error, :beam_lib, {:missing_chunk, _, _}} ->
          {:error, :missing_chunk}

        {:error, :beam_lib, {:file_error, _, reason}} ->
          {:error, {:file_error, reason}}

        {:error, :beam_lib, {kind, _}}
        when kind in [:not_a_beam_file, :invalid_beam_file] ->
          {:error, :invalid_beam}

        {:error, :beam_lib, {kind, _, _}}
        when kind in [:not_a_beam_file, :invalid_beam_file, :invalid_chunk] ->
          {:error, :invalid_beam}

        {:error, :beam_lib, _other} ->
          {:error, :invalid_beam}
      end
    rescue
      _ -> {:error, :invalid_beam}
    catch
      _, _ -> {:error, :invalid_beam}
    end
  end
end
