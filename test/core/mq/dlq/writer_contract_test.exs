defmodule Core.Mq.Dlq.WriterContractTest do
  # Writer — процесс со своим соединением: sandbox в shared mode.
  use Core.DataCase, async: false
  use Core.MqWriterContract, impl: Core.Mq.Dlq.Writer

  import ExUnit.CaptureLog

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

  test "неверные опции — ArgumentError на старте с именем опции" do
    Process.flag(:trap_exit, true)
    opts = [repo: TestRepo, subscriber_name: Mq.SubscriberName.new!("contract-opts")]

    for {opts, expected} <- [
          {Keyword.put(opts, :shutdown, 5_000), "unknown options [:shutdown]"},
          {Keyword.delete(opts, :subscriber_name), "required :subscriber_name option not found"},
          {Keyword.put(opts, :repo, nil), "invalid value for :repo option: ожидается модуль, получено nil"}
        ] do
      assert {{:error, {%ArgumentError{message: message}, _stack}}, _log} =
               with_log(fn -> Mq.Dlq.Writer.start_link(opts) end)

      assert message =~ "Core.Mq.Dlq.Writer.init/1: #{expected}"
    end
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
