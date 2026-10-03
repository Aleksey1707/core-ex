defmodule ConsumerTest.Outbox do
  @moduledoc "Результат `topic/0` модуля outbox и поллер очереди, поднятый деревом `Core.Outbox.Supervisor`."

  alias Consumer.Domain.Sales.Order
  alias Core.Mq

  # топик — строка, а не Prim
  # expect: incompatible types given to Core.Mq.Topic.value/1
  def topic_as_prim, do: Mq.Topic.value(Order.Outbox.topic())

  def outbox_child, do: Core.Outbox.Supervisor.child_spec(outbox_opts())

  def outbox_watch_list, do: Core.Outbox.Supervisor.watch_list(outbox_opts())

  defp outbox_opts do
    [
      enabled: true,
      cluster_query: nil,
      repo: Core.Outbox.Repo.Pg,
      pollers: [
        [
          name: ConsumerTest.Outbox.Poller,
          label: "stream",
          topics: {:only, [Order.Outbox.topic()]},
          writer: {Core.Mq.Stream.Writer, name: ConsumerTest.Outbox.Writer}
        ]
      ],
      poll_interval_ms: 1_000,
      idle_min_ms: 50,
      batch_size: 100,
      lock_duration_seconds: 30,
      max_attempts: 10,
      published_ttl_seconds: 604_800,
      cleaner_interval_ms: 3_600_000
    ]
  end
end
