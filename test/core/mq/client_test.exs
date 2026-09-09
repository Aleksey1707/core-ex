defmodule Core.Mq.ClientTest do
  use ExUnit.Case, async: true

  alias Core.Mq

  @opts [
    label: "Core.Mq.Test",
    client: RabbitMQStream.Connection,
    adapter: Core.Mq.Stream.Connection,
    dep: :rabbitmq_stream,
    requirement: "~> 0.4"
  ]

  test "клиент и адаптер на месте — :ok" do
    assert :ok = Mq.Client.ensure_available!(@opts)
  end

  test "клиента нет в сборке — про deps приложения" do
    opts = Keyword.put(@opts, :client, NoSuchBrokerClient)

    assert_raise ArgumentError, ~r/клиент :rabbitmq_stream не найден — добавьте/, fn ->
      Mq.Client.ensure_available!(opts)
    end
  end

  test "клиент есть, адаптера нет — про пересборку библиотеки" do
    opts = Keyword.put(@opts, :adapter, NoSuchBrokerAdapter)

    assert_raise ArgumentError, ~r/собрана без него — пересоберите/, fn ->
      Mq.Client.ensure_available!(opts)
    end
  end

  test "опечатка в собственных опциях названа по имени" do
    assert_raise ArgumentError, ~r/нет обязательной опции :dep/, fn ->
      Mq.Client.ensure_available!(Keyword.delete(@opts, :dep))
    end
  end
end
