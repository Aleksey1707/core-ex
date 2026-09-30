defmodule Core.Mq.Dlq.WriterContractTest do
  # Writer — процесс со своим соединением: sandbox в shared mode.
  use Core.DataCase, async: false
  use Core.MqWriterContract, impl: Core.Mq.Dlq.Writer

  alias Core.Mq

  # Отказ записи с заданного индекса — триггер на подписчика `contract-fail-<индекс>`: DDL живёт
  # в транзакции sandbox и откатывается вместе с тестом.
  setup do
    TestRepo.query!("""
    CREATE FUNCTION mq_dlq_contract_fail() RETURNS trigger AS $$
    BEGIN
      IF NEW.subscriber_name LIKE 'contract-fail-%' AND
         (SELECT count(*) FROM mq_dlq WHERE subscriber_name = NEW.subscriber_name) >=
           split_part(NEW.subscriber_name, '-', 3)::integer THEN
        RAISE EXCEPTION 'contract fail';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    TestRepo.query!(
      "CREATE TRIGGER mq_dlq_contract_fail BEFORE INSERT ON mq_dlq FOR EACH ROW EXECUTE FUNCTION mq_dlq_contract_fail()"
    )

    :ok
  end

  # ---

  defp ok_writer, do: start_writer("contract-ok")

  defp failing_writer(index), do: start_writer("contract-fail-#{index}")

  defp start_writer(subscriber) do
    name = :"dlq_writer_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Core.Mq.Dlq.Writer, repo: TestRepo, subscriber_name: Mq.SubscriberName.new!(subscriber), name: name},
      id: name
    )

    name
  end

  defp published(name) do
    %{subscriber: subscriber} = :sys.get_state(name)

    %{rows: rows} =
      TestRepo.query!("SELECT body FROM mq_dlq WHERE subscriber_name = $1 ORDER BY id", [subscriber])

    List.flatten(rows)
  end

  defp message(body) do
    {:ok, message} = Mq.Message.new(Mq.Topic.new!("contract"), %{}, body, Mq.Key.new!("agg-1"))

    message
  end
end
