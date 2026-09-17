defmodule Core.Es.Projection.Await do
  @moduledoc """
  Ожидание проекции после записи — тело `await/3` модуля проекции: цель, отметка дерева
  `Core.Es.Projection.Supervisor`, сигнал и шаги чекпоинта (`await: :poll`) или прогон проекции
  в вызывающем процессе (`await: :inline`). Исходы — в `@moduledoc` `Core.Es.Projection`,
  «Ожидание».
  """

  alias Core.Error
  alias Core.Es
  alias Core.Es.Projection
  alias Core.Es.Projection.Batch
  alias Core.Es.Projection.Checkpoint
  alias Core.Otel
  alias Core.Telemetry

  require Error

  @doc """
  Дождаться, пока проекция `projection` по объявлению `declaration` обработает последнее событие
  потока `aggregate_id` типа агрегата `type`, — не дольше `timeout` мс.
  """
  @spec run(module(), Projection.t(), String.t(), struct(), non_neg_integer()) ::
          :ok | {:error, Error.t()}

  def run(projection, declaration, type, %_{} = aggregate_id, timeout)
      when is_atom(projection) and is_binary(type) and is_integer(timeout) and timeout >= 0 do
    ensure_outside_transaction!(declaration.dao.in_transaction?(), declaration)
    mark = tree_mark!(Projection.Supervisor.Mark.find(), projection, declaration)
    id = declaration.codec.dump(aggregate_id)

    Otel.Es.await(declaration.name, type, id, fn ->
      measured(declaration, fn -> awaited(mark, projection, declaration, {type, id}, timeout) end)
    end)
  end

  # ---

  defp ensure_outside_transaction!(false, _declaration), do: :ok

  defp ensure_outside_transaction!(true, declaration) do
    raise ArgumentError,
          "Es.Projection.await: проекция #{declaration.name} вызвана внутри транзакции — " <>
            "пачка не видит незакоммиченной записи, ожидание идёт после commit"
  end

  defp tree_mark!(nil, _projection, _declaration) do
    raise "Es.Projection.await: дерево проекций не запущено — " <>
            "Core.Es.Projection.Supervisor на ноде не стартовал"
  end

  defp tree_mark!(%{projections: projections} = mark, projection, declaration) do
    :ok = ensure_listed!(projection in projections, declaration)
    mark
  end

  defp ensure_listed!(true, _declaration), do: :ok

  defp ensure_listed!(false, declaration) do
    raise ArgumentError,
          "Es.Projection.await: проекция #{declaration.name} не из projections: " <>
            "дерева проекций"
  end

  defp measured(declaration, fun) do
    start = System.monotonic_time()
    result = fun.()

    :telemetry.execute(
      Telemetry.event([:es, :projection, :await]),
      %{duration: System.monotonic_time() - start},
      %{projection: declaration.name, result: telemetry_result(result)}
    )

    result
  end

  defp telemetry_result(:ok), do: :ok
  defp telemetry_result({:error, %Error{code: :projection_timeout}}), do: :timeout
  defp telemetry_result({:error, %Error{code: :projection_rebuilding}}), do: :rebuilding

  defp awaited(%{await: :inline} = mark, projection, declaration, stream, _timeout) do
    case target(declaration, stream) do
      nil -> :ok
      target -> inline(projection, declaration, mark.batch_size, target)
    end
  end

  # Подписка — до чтения цели и чекпоинта: сигнал между чтением и ожиданием иначе потерялся бы.
  defp awaited(%{await: :poll} = mark, _projection, declaration, stream, timeout) do
    subscription = Projection.Registry.subscribe_checkpoint(declaration.name)

    try do
      subscribed(mark, declaration, stream, timeout, subscription)
    after
      :ok = Projection.Registry.unsubscribe_checkpoint(declaration.name, subscription)
    end
  end

  defp target(declaration, {type, id}),
    do: Es.Store.last_stream_position(declaration.dao, type, id)

  # Тестовое дерево: пачки идут в процессе и транзакции вызывающего до `:idle`, затем чекпоинт
  # сверяется с целью. Иной исход — дефект теста или проекции, а не ожидание.
  defp inline(projection, declaration, batch_size, target) do
    case until_idle(projection, declaration, batch_size) do
      :idle -> verified(declaration, target)
      {:error, %Error{} = error, _failure} -> raise_inline!(declaration, {:error, error})
      outcome -> raise_inline!(declaration, outcome)
    end
  end

  defp until_idle(projection, declaration, batch_size) do
    case Batch.run(projection, declaration, batch_size) do
      {:processed, _event_count} -> until_idle(projection, declaration, batch_size)
      outcome -> outcome
    end
  end

  defp verified(declaration, target) do
    case progress(Checkpoint.find(declaration), declaration, target) do
      :reached -> :ok
      progress -> raise_inline!(declaration, {:idle, progress})
    end
  end

  defp raise_inline!(declaration, outcome) do
    raise "Es.Projection.await: прогон :inline проекции #{declaration.name} — " <>
            "исход #{inspect(outcome)}"
  end

  # Таймаут и шаги — от начала ожидания; шаг — пара «когда наступает, длина».
  defp subscribed(mark, declaration, stream, timeout, subscription) do
    started = System.monotonic_time(:millisecond)

    awaiting = %{
      declaration: declaration,
      target: target(declaration, stream),
      subscription: subscription,
      timeout: timeout,
      deadline: started + timeout,
      max_ms: mark.await_max_ms
    }

    poll(awaiting, {started + mark.await_min_ms, mark.await_min_ms})
  end

  defp poll(%{target: nil}, _step), do: :ok

  defp poll(%{declaration: declaration} = awaiting, step) do
    case progress(Checkpoint.find(declaration), declaration, awaiting.target) do
      :reached -> :ok
      :rebuilding -> {:error, rebuilding(declaration)}
      :behind -> wait(awaiting, step)
    end
  end

  # Проекция в повторе чекпоинт не двигает: ожидание идёт до таймаута, как у отстающей. Шаги идут
  # по расписанию и сигналами не сдвигаются: поток сигналов занятой проекции не отменяет их.
  defp wait(awaiting, {step_at, _interval} = step) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= awaiting.deadline -> {:error, timed_out(awaiting.declaration, awaiting.timeout)}
      now >= step_at -> stepped(awaiting, step)
      true -> signaled(awaiting, step, min(step_at, awaiting.deadline) - now)
    end
  end

  defp signaled(awaiting, step, timeout) do
    case Projection.Registry.receive_checkpoint(awaiting.subscription, timeout) do
      :signal -> poll(awaiting, step)
      :timeout -> wait(awaiting, step)
    end
  end

  # Шаг будит читателя: пачка при `wake` после записи могла не увидеть событие за старой пишущей
  # транзакцией.
  defp stepped(awaiting, {step_at, interval}) do
    :ok = Projection.Registry.wake_projection(awaiting.declaration.name)
    next = min(interval * 2, awaiting.max_ms)
    poll(awaiting, {step_at + next, next})
  end

  # Чекпоинт не ниже цели — событие потока строка уже обработала, при любой её версии и во время
  # пересборки. Ниже цели строка старой версии или чекпоинт ниже цели пересборки — read-модель
  # неполна, ждать её пересборку до таймаута незачем.
  defp progress(nil, _declaration, _target), do: :rebuilding

  defp progress(%{position: position} = checkpoint, declaration, target) do
    cond do
      reached?(position, target) -> :reached
      Checkpoint.rebuilding?(checkpoint, declaration) -> :rebuilding
      true -> :behind
    end
  end

  defp reached?(nil, _target), do: false
  defp reached?(position, target), do: position >= target

  defp timed_out(declaration, timeout) do
    Error.app(
      code: :projection_timeout,
      ns: :es,
      message: "Проекция не обработала запись за время ожидания",
      detail: %{projection: declaration.name, timeout: timeout}
    )
  end

  defp rebuilding(declaration) do
    Error.app(
      code: :projection_rebuilding,
      ns: :es,
      message: "Проекция пересобирается: read-модель неполна",
      detail: %{projection: declaration.name}
    )
  end
end
