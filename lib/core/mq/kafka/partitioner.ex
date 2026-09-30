defmodule Core.Mq.Kafka.Partitioner do
  @moduledoc """
  Раскладка ключа по партициям, совместимая с `DefaultPartitioner` Kafka.

  Партиция ключа — `toPositive(murmur2(key)) % count`, как у Java-клиента и прежнего
  клиента `:klife`: сообщение с тем же ключом попадает в ту же партицию при любом продюсере
  топика. Встроенный `hash` у `:brod` — `erlang:phash2/1`, и порядок по ключу на нём рвётся
  (ADR-0034). Без ключа — случайная партиция.

  Клиента не требует и компилируется всегда.
  """

  import Bitwise

  @seed 0x9747B28C
  @m 0x5BD1E995
  @r 24
  @mask 0xFFFFFFFF

  @doc "Партиция для ключа (байты) среди `count` партиций; без ключа — случайная."
  @spec partition(binary() | nil, pos_integer()) :: non_neg_integer()

  def partition(nil, count) when is_integer(count) and count > 0, do: :rand.uniform(count) - 1

  def partition(key, count) when is_binary(key) and is_integer(count) and count > 0,
    do: rem(band(murmur2(key), 0x7FFFFFFF), count)

  @doc "`Utils.murmur2` Java-клиента Kafka: знаковое 32-битное целое."
  @spec murmur2(binary()) :: integer()

  def murmur2(data) when is_binary(data) do
    hash = finalize(blocks(data, bxor(@seed, byte_size(data))))

    if hash >= 0x80000000, do: hash - 0x100000000, else: hash
  end

  # ---

  defp blocks(<<k::little-32, rest::binary>>, h) do
    k = mul(k)
    k = mul(bxor(k, k >>> @r))

    blocks(rest, bxor(mul(h), k))
  end

  defp blocks(<<b1, b2, b3>>, h), do: mul(bxor(h, b3 <<< 16 ||| b2 <<< 8 ||| b1))
  defp blocks(<<b1, b2>>, h), do: mul(bxor(h, b2 <<< 8 ||| b1))
  defp blocks(<<b1>>, h), do: mul(bxor(h, b1))
  defp blocks(<<>>, h), do: h

  defp finalize(h) do
    h = mul(bxor(h, h >>> 13))
    bxor(h, h >>> 15)
  end

  defp mul(x), do: x * @m &&& @mask
end
