defmodule Core.MqWriterContract do
  @moduledoc """
  Общий набор тестов контракта `Core.Mq.Writer` — прогоняется на каждой реализации.

  Реализаций несколько (`Mq.Stream.Writer`, `Mq.Kafka.Writer`, `MqFake.Writer`), а порядок
  публикации и индекс первой неуспешной записи — то, на чём стоит outbox: разойдись они,
  поллер пометит `published` неопубликованное (`19-testing.md`, «Контрактные тесты
  behaviour»).

  Хост-модуль определяет четыре функции:

  - `ok_writer/0` — handle, публикующий успешно;
  - `failing_writer/1` — handle, у которого публикация проваливается начиная с индекса;
  - `message/1` — `Mq.Message` с телом-меткой (реализация вправе разводить их по топикам);
  - `published/1` — тела реально опубликованных сообщений в порядке публикации.
  """

  @doc "Подключить набор: `use Core.MqWriterContract, impl: Mq.Kafka.Writer`."
  defmacro __using__(impl: impl) do
    quote do
      @writer_impl unquote(impl)

      test "put публикует одно сообщение" do
        assert :ok = @writer_impl.put(ok_writer(), message("a"))
      end

      test "put_many публикует пачку строго по порядку" do
        writer = ok_writer()

        assert :ok = @writer_impl.put_many(writer, [message("a"), message("b"), message("c")])
        assert published(writer) == ~w(a b c)
      end

      test "хвост пачки после первой ошибки не публикуется" do
        writer = failing_writer(1)

        assert {:error, 1, %Core.Error{}} =
                 @writer_impl.put_many(writer, [message("a"), message("b"), message("c")])

        # Poller считает опубликованным всё до индекса — ни записью больше.
        assert published(writer) == ~w(a)
      end

      test "put_many пустой пачки — :ok" do
        assert :ok = @writer_impl.put_many(ok_writer(), [])
      end

      test "put_many останавливается на первой ошибке и отдаёт её индекс" do
        writer = failing_writer(1)

        assert {:error, 1, %Core.Error{}} =
                 @writer_impl.put_many(writer, [message("a"), message("b"), message("c")])
      end

      test "put разворачивает ошибку пачки в ошибку без индекса" do
        assert {:error, %Core.Error{}} = @writer_impl.put(failing_writer(0), message("a"))
      end
    end
  end
end
