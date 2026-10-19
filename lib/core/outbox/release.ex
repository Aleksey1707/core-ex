defmodule Core.Outbox.Release do
  @moduledoc """
  Команда оператора outbox для релиза, где Mix нет (`bin/my_app eval`).

  Приложение зовёт её из своей задачи релиза, загрузив конфигурацию:

      defmodule MyAppApp.Release do
        def outbox_requeue(target) do
          Application.load(:my_app)
          Core.Outbox.Release.requeue(target)
        end
      end

      bin/my_app eval 'MyAppApp.Release.outbox_requeue(:all)'
      bin/my_app eval 'MyAppApp.Release.outbox_requeue([Core.Outbox.ID.new!("0199c0e2-...")])'

  Переопубликация окна после восстановления базы приложение загружает сама:

      def outbox_republish_since(since), do: Core.Outbox.Release.republish_since(:my_app, since)

      bin/my_app eval 'MyAppApp.Release.outbox_republish_since(~U[2026-10-19 09:00:00Z])'

  Ответ оператору — `IO.puts`: Mix в релизе нет (`20-agreements.md`, «Логирование»). То же из
  корня приложения — `mix outbox.requeue`.
  """

  alias Core.Config
  alias Core.Context
  alias Core.Es
  alias Core.Exc
  alias Core.Helper.Transact
  alias Core.Outbox
  alias Core.Result

  @label "Outbox.Release"
  @chunk_size 500

  # ===== возврат в очередь =====

  @doc """
  Вернуть `:failed`-записи в очередь (`requeue_failed/2` репозитория `Core.Config.outbox_repo/0`) и
  сообщить их число.

  На время команды поднимается `Core.Config.dao/0` (`Ecto.Migrator.with_repo/2`), если ещё не
  запущен; записи забирает уже работающий поллер.
  """
  @spec requeue(:all | [Outbox.ID.t()]) :: :ok

  def requeue(:all), do: requeue_failed(:all)
  def requeue(ids) when is_list(ids), do: requeue_failed(ids)

  # ---

  defp requeue_failed(target) do
    repo = Config.outbox_repo()

    {:ok, count, _apps} =
      Ecto.Migrator.with_repo(Config.dao(), fn _dao -> repo.requeue_failed(target, Context.new()) end)

    IO.puts("Возвращено в очередь: #{count}")
  end

  # ===== переопубликация окна =====

  @doc """
  Переопубликовать события окна после восстановления базы на момент T: строки хранилища событий с
  `at` не раньше `since` снова становятся записями outbox `:new`, и сообщить их число по топикам.

  - Топики находятся сами: каждый outbox-модуль (`use Core.Es.Outbox`) среди модулей `app` даёт
    топик, а кодек событий его семейства — тип агрегата. Агрегат с `outbox: :none` модуля не имеет
    и пропускается.
  - Строки идут в порядке commit (`xid`, `number`). Запись собирается из колонок без декодирования
    события — так же, как на пути записи (`Core.Es.Outbox`): конверт с ключами операции, ключ —
    `aggregate_id`, имя — тег, заголовки `name`, `aggr_id`, `event_id`, `operation_id`, без
    `traceparent`. ПДн-значения остаются шифротекстом строки.
  - Всё окно — одна транзакция `Core.Config.dao/0` без таймаута: отказ любой записи откатывает
    окно целиком (`Core.Exc`).
  - Строка вывода — на каждый найденный топик, `0` — событий окна у него нет. Outbox-модуль без
    кодека своего семейства среди модулей `app` и два outbox-модуля одного типа — `ArgumentError`
    до записи.

  Приложение задача загружает сама и не стартует: на время команды поднимается только
  `Core.Config.dao/0` (`Ecto.Migrator.with_repo/2`), записи забирает уже работающий поллер.
  """
  @spec republish_since(atom(), DateTime.t()) :: :ok

  def republish_since(app, %DateTime{} = since) when is_atom(app) do
    topics = topics_by_type(app)

    {:ok, counts, _apps} = Ecto.Migrator.with_repo(Config.dao(), &republish(&1, topics, since))

    for {topic, count} <- Enum.sort(counts), do: IO.puts("Переопубликовано в #{topic}: #{count}")
    :ok
  end

  # ---

  defp topics_by_type(app) do
    modules = Enum.filter(app_modules(app), &Code.ensure_loaded?/1)

    type_by_family =
      for module <- modules, event_codec?(module), into: %{}, do: {module.__codec_union__(), module.__es_type__()}

    modules
    |> Enum.filter(&outbox?/1)
    |> Enum.reduce(%{}, &put_topic!(&1, &2, type_by_family))
  end

  defp app_modules(app) do
    case Application.load(app) do
      :ok -> Application.spec(app, :modules)
      {:error, {:already_loaded, ^app}} -> Application.spec(app, :modules)
      {:error, reason} -> raise ArgumentError, "#{@label}: приложение #{inspect(app)} не загружено: #{inspect(reason)}"
    end
  end

  defp event_codec?(module), do: function_exported?(module, :__es_type__, 0)

  defp outbox?(module), do: function_exported?(module, :__es_event__, 0) and function_exported?(module, :topic, 0)

  defp put_topic!(outbox, topics, type_by_family) do
    family = outbox.__es_event__()

    case Map.fetch(type_by_family, family) do
      {:ok, type} when is_map_key(topics, type) ->
        raise ArgumentError, "#{@label}: у типа агрегата #{type} два outbox-модуля, второй — #{inspect(outbox)}"

      {:ok, type} ->
        Map.put(topics, type, Outbox.Topic.new!(outbox.topic()))

      :error ->
        raise ArgumentError,
              "#{@label}: кодек событий семейства #{inspect(family)} у #{inspect(outbox)} не найден"
    end
  end

  defp republish(dao, topics, since) do
    case Transact.run(dao, fn -> append_window(dao, topics, since) end, timeout: :infinity) do
      {:ok, counts} -> counts
      {:error, error} -> raise Exc, error
    end
  end

  defp append_window(dao, topics, since) do
    initial = Map.new(Map.values(topics), &{Outbox.Topic.value(&1), 0})

    dao
    |> Es.Store.stream_since(Map.keys(topics), since)
    |> Stream.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, initial}, &append_chunk(&1, &2, topics))
  end

  defp append_chunk(rows, {:ok, counts}, topics) do
    with {:ok, records} <- Result.traverse(rows, &record(&1, topics)),
         :ok <- Config.outbox_repo().append(records, Context.new()) do
      {:cont, {:ok, Enum.reduce(records, counts, &count/2)}}
    else
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp record(row, topics), do: Es.Outbox.record(Map.fetch!(topics, row.aggregate_type), Es.Store.Schema.to_wire(row))

  defp count(record, counts), do: Map.update!(counts, Outbox.Topic.value(record.topic), &(&1 + 1))
end
