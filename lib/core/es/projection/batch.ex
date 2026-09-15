defmodule Core.Es.Projection.Batch do
  @moduledoc """
  Транзакция пачки проекции — тело `Core.Es.Projection.run_once/2` и цикла
  `Core.Es.Projection.Reader`: блокировка, чекпоинт, события после него, `project/1` и CAS
  чекпоинта. Шаги и исходы — в `@moduledoc` `Core.Es.Projection`.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Es.Projection
  alias Core.Es.Projection.Checkpoint
  alias Core.Helper.Transact
  alias Core.Otel

  require Error
  require Logger

  @typedoc """
  Отказ пачки: чекпоинт до пачки (`nil` — начало истории) и событие, на котором она отказала
  (`nil` — не на событии).
  """
  @type failure :: %{position: Es.Store.position() | nil, event_id: String.t() | nil}

  @typedoc "Исход пачки: `:processed` — с числом прочитанных событий, отказ — с `t:failure/0`."
  @type result ::
          {:processed, non_neg_integer()}
          | :idle
          | :locked
          | :outdated
          | {:error, Error.t(), failure()}

  @doc "Прогнать пачку проекции `projection` по её объявлению `declaration`."
  @spec run(module(), Projection.t(), pos_integer()) :: result()

  def run(projection, %{dao: dao} = declaration, batch_size)
      when is_atom(projection) and is_integer(batch_size) and batch_size > 0 do
    ensure_outside_transaction!(dao.in_transaction?(), declaration)

    case Transact.run(dao, fn -> locked(projection, declaration, batch_size) end) do
      {:ok, result} -> result
      {:error, {%Error{} = error, failure}} -> {:error, error, failure}
    end
  end

  # ---

  defp ensure_outside_transaction!(false, _declaration), do: :ok

  defp ensure_outside_transaction!(true, declaration) do
    raise ArgumentError,
          "Es.Projection.run_once: проекция #{declaration.name} вызвана внутри транзакции — " <>
            "пачка открывает свою"
  end

  defp locked(projection, declaration, batch_size) do
    case Checkpoint.try_lock(declaration) do
      true -> checkpointed(projection, declaration, batch_size)
      false -> {:ok, :locked}
    end
  end

  defp checkpointed(projection, %{version: version} = declaration, batch_size) do
    case Checkpoint.find(declaration) do
      nil ->
        start(projection, declaration, nil)

      %{version: older} = checkpoint when older < version ->
        start(projection, declaration, checkpoint)

      %{version: ^version} = checkpoint ->
        advance(projection, declaration, checkpoint, batch_size)

      %{version: newer} when newer > version ->
        {:ok, :outdated}
    end
  end

  # Строки нет или её версия ниже — старт с начала истории: read-модель очищается, строка встаёт в
  # начало со своей версией и целью пересборки — последней позицией событий, видимой пачке. Без
  # событий цель пуста и пересборка завершена сразу.
  defp start(projection, declaration, checkpoint) do
    traced(declaration, true, 0, checkpoint && checkpoint.position, fn ->
      with :ok <- callback(declaration, :clear, nil, fn -> projection.clear() end),
           target = Es.Store.last_position(declaration.dao, Map.keys(declaration.streams)),
           :ok <- Checkpoint.start(declaration, checkpoint, target) do
        log_started(declaration, checkpoint, target)
        {:ok, nil}
      end
    end)
  end

  defp log_started(declaration, checkpoint, target) do
    Logger.info(
      "проекция: старт с начала истории: projection=#{declaration.name} " <>
        "from_version=#{inspect(checkpoint && checkpoint.version)} to_version=#{declaration.version}"
    )

    if target == nil, do: log_reached(declaration)
  end

  defp advance(projection, declaration, checkpoint, batch_size) do
    types = Map.keys(declaration.streams)

    case Es.Store.list_after(declaration.dao, types, checkpoint.position, batch_size) do
      [] ->
        {:ok, :idle}

      rows ->
        traced(declaration, false, length(rows), checkpoint.position, fn ->
          project_rows(projection, declaration, checkpoint, rows)
        end)
    end
  end

  defp traced(declaration, reset?, event_count, from, fun) do
    Otel.Es.project(declaration.name, declaration.version, fn ->
      :ok = Otel.Es.batch(reset?, event_count, from)
      traced_result(fun.(), event_count, from)
    end)
  end

  defp traced_result({:ok, to}, event_count, _from) do
    :ok = Otel.Es.checkpoint(to)
    {:ok, {:processed, event_count}}
  end

  defp traced_result({:error, error}, event_count, from),
    do: traced_result({:error, error, nil}, event_count, from)

  # Транзакция откатывается по `{:error, _}`: отказ уходит из неё одним значением вместе с позицией
  # чекпоинта и событием — их пишет в `warning` читатель.
  defp traced_result({:error, %Error{} = error, event_id}, _event_count, from) do
    :ok = Otel.Es.failed(error, event_id)
    {:error, {error, %{position: from, event_id: event_id}}}
  end

  defp project_rows(projection, declaration, checkpoint, rows) do
    to = List.last(rows).position

    with :ok <- project_each(projection, declaration, rows),
         :ok <- Checkpoint.move(declaration, checkpoint, to) do
      if reached?(checkpoint, to), do: log_reached(declaration)
      {:ok, to}
    end
  end

  # Цель достигнута пачкой, которая перевела чекпоинт с позиции ниже цели на цель или дальше.
  defp reached?(%{target: nil}, _to), do: false

  defp reached?(%{position: from, target: target}, to),
    do: below?(from, target) and not below?(to, target)

  defp below?(nil, _target), do: true
  defp below?(position, target), do: position < target

  defp log_reached(declaration) do
    Logger.info(
      "проекция: цель пересборки достигнута: projection=#{declaration.name} " <>
        "version=#{declaration.version}"
    )
  end

  defp project_each(_projection, _declaration, []), do: :ok

  defp project_each(projection, declaration, [row | rows]) do
    case project_row(projection, declaration, row) do
      :ok -> project_each(projection, declaration, rows)
      {:error, error} -> {:error, error, row.event_id}
    end
  end

  # Тег сверяется после цепочки `upcasts:`, без загрузки: необъявленный, но известный кодеку тег
  # пропускается, а неизвестный грузится — и загрузка отдаёт ошибку, а не пропуск.
  defp project_row(projection, declaration, row) do
    %{codec: event_codec, tags: declared} = Map.fetch!(declaration.streams, row.type)
    tag = current_tag(row.tag, event_codec.__es_upcasts__())

    if skipped?(tag, declared, event_codec),
      do: :ok,
      else: load_and_project(projection, declaration, event_codec, row)
  end

  defp current_tag(tag, upcasts) do
    case Map.fetch(upcasts, tag) do
      {:ok, next} -> current_tag(next, upcasts)
      :error -> tag
    end
  end

  defp skipped?(tag, declared, event_codec),
    do: not MapSet.member?(declared, tag) and MapSet.member?(event_codec.types(), tag)

  defp load_and_project(projection, declaration, event_codec, row) do
    with {:ok, event} <- declaration.codec.load(event_codec.__codec_union__(), row.wire) do
      callback(declaration, :project, row.event_id, fn -> projection.project(event) end)
    end
  end

  # Исключение колбэка откатывает пачку так же, как `{:error, _}`. Текст исключения уходит только
  # в лог внутри span'а пачки: ошибка несёт модуль исключения, текст мог бы нести данные.
  defp callback(declaration, name, event_id, fun) do
    checked(fun.())
  rescue
    exception ->
      log_raised(declaration, name, event_id, exception, __STACKTRACE__)
      {:error, raised(declaration, name, exception)}
  end

  defp checked(:ok), do: :ok
  defp checked({:error, %Error{}} = error), do: error

  defp log_raised(declaration, callback, event_id, exception, stacktrace) do
    Logger.warning(
      "проекция: исключение колбэка: projection=#{declaration.name} callback=#{callback} " <>
        "event_id=#{event_id} " <> Exception.format(:error, exception, stacktrace)
    )
  end

  defp raised(declaration, callback, %exception{}) do
    Error.app(
      code: :projection_raised,
      ns: :es,
      detail: %{projection: declaration.name, callback: callback, exception: exception}
    )
  end
end
