defmodule Core.Mq.Kafka.PartitionerTest do
  use ExUnit.Case, async: true

  alias Core.Mq.Kafka.Partitioner

  # Эталон — `UtilsTest.testMurmur2` Java-клиента Kafka: `Utils.murmur2` возвращает знаковый int.
  @java_murmur2 [
    {"21", -973_932_308},
    {"foobar", -790_332_482},
    {"a-little-bit-long-string", -985_981_536},
    {"a-little-bit-longer-string", -1_486_304_829},
    {"lkjh234lh9fiuh90y23oiuhsafujhadof229phr9h19h89h8", -58_897_971},
    {"abc", 479_470_107}
  ]

  test "murmur2 совпадает с Utils.murmur2 Java-клиента" do
    for {key, hash} <- @java_murmur2, do: assert(Partitioner.murmur2(key) == hash, key)
  end

  test "ключ → партиция как у DefaultPartitioner: toPositive(murmur2(key)) % count" do
    assert Enum.map(@java_murmur2, fn {key, _hash} -> Partitioner.partition(key, 7) end) ==
             [3, 0, 1, 0, 3, 4]
  end

  test "одна партиция — всегда нулевая" do
    for {key, _hash} <- @java_murmur2, do: assert(Partitioner.partition(key, 1) == 0)
  end

  test "без ключа — случайная партиция в пределах числа партиций" do
    partitions = for _ <- 1..200, do: Partitioner.partition(nil, 3)

    assert MapSet.new(partitions) == MapSet.new([0, 1, 2])
  end
end
