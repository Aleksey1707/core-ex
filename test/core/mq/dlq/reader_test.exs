defmodule Core.Mq.Dlq.ReaderTest do
  # Читатель — процесс со своим соединением: sandbox в shared mode.
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Dlq
  alias Core.Mq.Dlq.Store

  @topic Mq.Topic.new!("orders")

  setup do
    subscriber = Mq.SubscriberName.new!("dlq-#{System.unique_integer([:positive])}")
    reader = start_supervised!({Dlq.Reader, repo: TestRepo, topic: @topic, subscriber_name: subscriber})

    {:ok, subscriber: subscriber, reader: reader}
  end

  test "commit без сообщения в работе — :nothing_to_commit", %{reader: reader} do
    assert {:error, %Error{code: :nothing_to_commit}} = Dlq.Reader.commit(reader)
  end

  test "get с таймаутом дожидается возвращённой записи", %{reader: reader, subscriber: subscriber} do
    insert!(subscriber, "late")

    task = Task.async(fn -> Dlq.Reader.get(reader, 2_000) end)
    Process.sleep(150)
    Dlq.requeue(TestRepo, :all)

    assert {:ok, %Mq.Message{body: "late"}} = Task.await(task)
  end

  test "перехваченная запись брошена с warning, commit её отклонён", %{reader: reader, subscriber: subscriber} do
    insert!(subscriber, "a")
    insert!(subscriber, "b")
    Dlq.requeue(TestRepo, :all)

    assert {:ok, %Mq.Message{body: "a"}} = Dlq.Reader.get(reader, 0)
    TestRepo.query!("UPDATE mq_dlq SET lease_id = $1 WHERE body = 'a'", [Store.new_lease()])

    log = capture_log(fn -> assert {:ok, %Mq.Message{body: "b"}} = Dlq.Reader.get(reader, 0) end)
    assert log =~ "захват записи перехвачен"

    TestRepo.query!("UPDATE mq_dlq SET lease_id = $1 WHERE body = 'b'", [Store.new_lease()])

    capture_log(fn -> assert {:error, %Error{code: :dlq_lease_lost}} = Dlq.Reader.commit(reader) end)
    assert {:error, %Error{code: :nothing_to_commit}} = Dlq.Reader.commit(reader)
  end

  test "остановка отдаёт захват сразу", %{reader: reader, subscriber: subscriber} do
    insert!(subscriber, "a")
    Dlq.requeue(TestRepo, :all)

    assert {:ok, _} = Dlq.Reader.get(reader, 0)
    stop_supervised!(Dlq.Reader)

    assert {:ok, %{body: "a"}} =
             Store.claim(TestRepo, Mq.SubscriberName.value(subscriber), "orders", Store.new_lease(), 1_000)
  end

  # ---

  defp insert!(subscriber, body) do
    Store.insert(TestRepo, %{
      subscriber: Mq.SubscriberName.value(subscriber),
      topic: "orders",
      key: nil,
      header_names: [],
      header_values: [],
      body: body,
      partition: nil,
      offset: nil,
      reason: "rejected",
      error: nil,
      attempts: 1
    })
  end
end
