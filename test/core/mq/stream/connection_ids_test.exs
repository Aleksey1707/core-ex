defmodule Core.Mq.Stream.ConnectionIdsTest do
  use ExUnit.Case, async: false

  @moduletag :rabbit_stream

  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Mq.Stream.Reader
  alias Core.Mq.Stream.Writer

  # Номер подписки и producer'а в кадре протокола — один байт, а клиент выдаёт номера
  # счётчиком на процесс соединения, не переиспользуя. Своё соединение на тест — чтобы
  # счётчик начинался с 1.
  defmodule Conn do
    @moduledoc false
    use RabbitMQStream.Connection

    def producer_sequence(stream, reference),
      do: RabbitMQStream.Connection.query_producer_sequence(__MODULE__, stream, reference)
  end

  setup do
    opts =
      :core
      |> Application.fetch_env!(Core.Mq.Stream)
      |> Keyword.delete(:lazy)
      |> Mq.Stream.Credentials.new()
      |> Mq.Stream.Credentials.to_connection_opts()

    start_supervised!({Conn, opts})
    :ok = Conn.connect()

    stream = "connection_ids_test_#{System.unique_integer([:positive])}"
    :ok = Conn.create_stream(stream)

    {:ok, stream: stream}
  end

  test "reader с 256-й подпиской соединения читает и останавливается штатно", %{stream: stream} do
    for _ <- 1..255 do
      {:ok, id} = Conn.subscribe(stream, self(), :first, 1)
      :ok = Conn.unsubscribe(id)
    end

    publish(stream, "after-wrap")

    {:ok, reader} =
      Reader.start_link(
        connection: Conn,
        topic: Mq.Topic.new!(stream),
        subscriber_name: Mq.SubscriberName.new!("sub"),
        reliable?: true,
        initial_offset: :first,
        retry_min_ms: 10
      )

    assert {:ok, %Message{body: "after-wrap"}} = Reader.get(reader, 5_000)
    assert :ok = Reader.commit(reader)
    assert :ok = GenServer.stop(reader)
  end

  test "writer с 256-м producer'ом соединения публикует", %{stream: stream} do
    for i <- 1..255 do
      {:ok, id} = Conn.declare_producer(stream, "churn-#{i}")
      :ok = Conn.delete_producer(id)
    end

    {:ok, writer} = Writer.start_link(connection: Conn, reference_prefix: "connection-ids")
    {:ok, message} = Message.new(Mq.Topic.new!(stream), %{}, "after-wrap", Mq.Key.new!("k"))

    assert {:error, 0, %Core.Error{code: :connection_ids_exhausted}} = Writer.put_many(writer, [message])
    assert eventually(fn -> Writer.put_many(writer, [message]) == :ok end)

    :ok = Mq.Stream.Connection.connect()

    {:ok, reader} =
      Reader.start_link(
        connection: Mq.Stream.Connection,
        topic: Mq.Topic.new!(stream),
        subscriber_name: Mq.SubscriberName.new!("sub"),
        reliable?: true,
        initial_offset: :first
      )

    assert {:ok, %Message{body: "after-wrap"}} = Reader.get(reader, 5_000)
    GenServer.stop(reader)
  end

  defp publish(stream, body) do
    :ok = Mq.Stream.Connection.connect()
    {:ok, writer} = Writer.start_link(connection: Mq.Stream.Connection, reference_prefix: "connection-ids")
    {:ok, message} = Message.new(Mq.Topic.new!(stream), %{}, body, Mq.Key.new!("k"))
    :ok = Writer.put(writer, message)
    GenServer.stop(writer)
  end

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(100)
        eventually(check, attempts - 1)
    end
  end
end
