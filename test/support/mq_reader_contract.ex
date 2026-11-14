defmodule Core.MqReaderContract do
  @moduledoc """
  Общий набор тестов контракта `Core.Mq.ReaderReliable` — прогоняется на каждой реализации.

  Реализаций несколько (`Mq.Stream.Reader`, `Mq.Kafka.Reader`, `Mq.Dlq.Reader`), а «get без
  commit отдаёт то же сообщение» и «commit двигает позицию» — то, на чём стоит подписчик:
  разойдись они, сообщение потеряется или обработается дважды (`19-testing.md`, «Контрактные
  тесты behaviour»).

  Хост-модуль определяет две функции:

  - `start_reader/1` — handle читателя по контексту теста;
  - `publish/2` — опубликовать сообщение с телом (для DLQ — записать строку и вернуть её в
    очередь).
  """

  @doc "Подключить набор: `use Core.MqReaderContract, impl: Mq.Kafka.Reader`."
  defmacro __using__(impl: impl) do
    quote do
      @reader_impl unquote(impl)
      @reader_timeout 15_000
      @reader_empty_timeout 300

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      defp reader_call(fun, args), do: apply(@reader_impl, fun, args)

      test "get без commit возвращает то же сообщение, после commit — :empty", context do
        reader = start_reader(context)

        assert :ok = publish(reader, "a")
        assert {:ok, %Core.Mq.Message{body: "a"} = message} = @reader_impl.get(reader, @reader_timeout)
        assert {:ok, ^message} = @reader_impl.get(reader, @reader_timeout)
        assert :ok = @reader_impl.commit(reader)
        assert :empty = @reader_impl.get(reader, @reader_empty_timeout)
      end

      test "commit двигает позицию: тела приходят в порядке публикации", context do
        reader = start_reader(context)

        assert :ok = publish(reader, "a")
        assert :ok = publish(reader, "b")

        assert {:ok, %Core.Mq.Message{body: "a"}} = @reader_impl.get(reader, @reader_timeout)
        assert :ok = @reader_impl.commit(reader)

        assert {:ok, %Core.Mq.Message{body: "b"}} = @reader_impl.get(reader, @reader_timeout)
        assert :ok = @reader_impl.commit(reader)

        assert :empty = @reader_impl.get(reader, @reader_empty_timeout)
      end

      test "пустой reader ждёт таймаут и возвращает :empty", context do
        reader = start_reader(context)
        started = System.monotonic_time(:millisecond)

        assert :empty = @reader_impl.get(reader, 500)
        assert System.monotonic_time(:millisecond) - started >= 450
      end

      test "заявка на готовность приходит один раз", context do
        if Core.Helper.Module.exports?(@reader_impl, :notify_when_ready, 2) do
          reader = start_reader(context)

          assert {:ok, ref} = reader_call(:notify_when_ready, [reader, self()])
          assert :ok = publish(reader, "ready")
          assert_receive {:mq_ready, ^ref}, @reader_timeout
          refute_receive {:mq_ready, ^ref}, 200
        end
      end

      test "metrics/1 отдаёт topic и числовые gauges, иначе info/1 — topic", context do
        reader = start_reader(context)

        if Core.Helper.Module.exports?(@reader_impl, :metrics, 1) do
          assert %{topic: topic} = metrics = reader_call(:metrics, [reader])
          assert is_binary(topic)
          assert Enum.all?(Map.delete(metrics, :topic), fn {_key, value} -> is_number(value) end)

          if @reader_impl == Core.Mq.Dlq.Reader do
            assert :ok = publish(reader, "pending")
            assert {:ok, _message} = @reader_impl.get(reader, @reader_timeout)
            assert %{pending: 1} = reader_call(:metrics, [reader])
            assert :ok = @reader_impl.commit(reader)
            assert %{pending: 0} = reader_call(:metrics, [reader])
          end
        else
          assert Core.Helper.Module.exports?(@reader_impl, :info, 1)
          assert %{topic: topic} = reader_call(:info, [reader])
          assert is_binary(topic)
        end
      end
    end
  end
end
