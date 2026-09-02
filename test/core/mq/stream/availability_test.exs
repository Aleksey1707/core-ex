defmodule Core.Mq.Stream.AvailabilityTest do
  use ExUnit.Case, async: true

  alias Core.Mq.Stream

  # Живой брокер не нужен: проверка смотрит только на факт компиляции адаптера
  # (см. `10-architecture.md`), а в собственной сборке библиотеки клиент всегда есть.
  test "ensure_available!/0 проходит, когда клиент :rabbitmq_stream в deps" do
    assert :ok = Stream.ensure_available!()
  end
end
