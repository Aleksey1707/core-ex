defmodule Core.PromEx.Safe do
  @moduledoc """
  Изоляция сбоев источника метрик от polling-воркера PromEx.

  Провайдер данных ходит в БД, к процессу или по MFA: недоступный источник приходит
  исключением или `exit` и роняет polling-процесс целиком — вместе со всеми метриками
  группы, а не только с недоступной. Обёртка пропускает такой цикл: gauge остаётся
  stale (последнее известное значение), что честнее нуля, а причина уходит в лог.

  `detach_on_error: false` у `Polling.build/5` защищает от detach метрики, но не от
  падения процесса — это разные вещи.
  """

  require Logger

  @doc """
  Выполнить сбор метрик, проглотив исключение и `exit` источника.

  `label` — что собиралось, попадает в лог.
  """
  @spec execute(String.t(), (-> any())) :: :ok

  def execute(label, fun) when is_binary(label) and is_function(fun, 0) do
    _ = fun.()
    :ok
  rescue
    exception ->
      log_skipped(label, Exception.format(:error, exception, __STACKTRACE__))
  catch
    :exit, reason ->
      log_skipped(label, "exit reason=#{inspect(reason)}")
  end

  # ---

  defp log_skipped(label, detail) do
    Logger.warning("PromEx: сбор метрик пропущен (#{label}): #{detail}")
    :ok
  end
end
