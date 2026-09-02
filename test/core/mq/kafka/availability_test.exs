defmodule Core.Mq.Kafka.AvailabilityTest do
  use ExUnit.Case, async: true

  alias Core.Mq.Kafka

  # Живой брокер не нужен: проверка смотрит только на факт компиляции адаптера
  # (см. `10-architecture.md`), а в собственной сборке библиотеки клиент всегда есть.
  test "ensure_available!/0 проходит, когда клиент :klife в deps" do
    assert :ok = Kafka.ensure_available!()
  end
end
