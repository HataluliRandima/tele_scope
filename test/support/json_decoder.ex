defmodule TeleScope.Test.JSONDecoder do
  @moduledoc """
  Minimal, strict JSON decoder for tests. OTP 26 has no `:json` module and
  TeleScope has no JSON dependency; this lets every supported OTP version
  verify that reports are valid JSON. Raises on any malformed input
  (trailing data, raw control characters in strings, missing commas, ...).
  """

  def decode!(binary) when is_binary(binary) do
    {value, rest} = value(ws(binary))

    case ws(rest) do
      "" ->
        value

      other ->
        raise ArgumentError,
              "trailing data: #{inspect(binary_part(other, 0, min(40, byte_size(other))))}"
    end
  end

  defp ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: ws(rest)
  defp ws(bin), do: bin

  defp value("{" <> rest), do: object(ws(rest), %{})
  defp value("[" <> rest), do: array(ws(rest), [])
  defp value("\"" <> rest), do: string(rest, [])
  defp value("true" <> rest), do: {true, rest}
  defp value("false" <> rest), do: {false, rest}
  defp value("null" <> rest), do: {nil, rest}
  defp value(bin), do: number(bin)

  defp object("}" <> rest, acc), do: {acc, rest}

  defp object("\"" <> rest, acc) do
    {key, rest} = string(rest, [])
    ":" <> rest = ws(rest)
    {val, rest} = value(ws(rest))
    acc = Map.put(acc, key, val)

    case ws(rest) do
      "," <> rest -> object(ws(rest), acc)
      "}" <> rest -> {acc, rest}
    end
  end

  defp array("]" <> rest, []), do: {[], rest}

  defp array(bin, acc) do
    {val, rest} = value(bin)

    case ws(rest) do
      "," <> rest -> array(ws(rest), [val | acc])
      "]" <> rest -> {Enum.reverse([val | acc]), rest}
    end
  end

  defp string("\"" <> rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string("\\u" <> <<hex::binary-size(4), rest::binary>>, acc),
    do: string(rest, [<<String.to_integer(hex, 16)::utf8>> | acc])

  defp string("\\" <> <<c, rest::binary>>, acc), do: string(rest, [escape(c) | acc])

  defp string(<<c::utf8, rest::binary>>, acc) when c >= 0x20,
    do: string(rest, [<<c::utf8>> | acc])

  defp escape(?"), do: "\""
  defp escape(?\\), do: "\\"
  defp escape(?/), do: "/"
  defp escape(?n), do: "\n"
  defp escape(?r), do: "\r"
  defp escape(?t), do: "\t"
  defp escape(?b), do: "\b"
  defp escape(?f), do: "\f"

  defp number(bin) do
    [token | _] = Regex.run(~r/^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?/, bin)
    rest = binary_part(bin, byte_size(token), byte_size(bin) - byte_size(token))

    value =
      if String.contains?(token, [".", "e", "E"]),
        do: elem(Float.parse(token), 0),
        else: String.to_integer(token)

    {value, rest}
  end
end
