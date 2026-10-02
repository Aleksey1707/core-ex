defmodule ConsumerTest.Outbox do
  @moduledoc "Результат `topic/0` модуля outbox."

  alias Consumer.Domain.Sales.Order
  alias Core.Mq

  # топик — строка, а не Prim
  # expect: incompatible types given to Core.Mq.Topic.value/1
  def topic_as_prim, do: Mq.Topic.value(Order.Outbox.topic())
end
