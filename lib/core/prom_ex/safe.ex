defmodule Core.PromEx.Safe do
  @moduledoc """
  Изоляция сбоев источника метрик от polling-воркера PromEx.

  Провайдер данных ходит в БД, к процессу или по MFA: недоступный источник приходит
  исключением или `exit` и роняет polling-процесс целиком — вместе со всеми метриками
  группы, а не только с недоступной. Обёртка пропускает такой цикл: gauge остаётся
  stale (последнее известное значение), что честнее нуля, а причина уходит в лог.

  `detach_on_error: false` у `Polling.build/5` защищает от detach метрики, но не от
  падения процесса — это разные вещи.

  ## Сигнал отказа

  Застывший gauge неотличим от спокойного, поэтому каждый пропущенный цикл, кроме `warning`,
  эмитит `error_event/1` плагина с тегом `collector` — закрытым именем polling-группы
  (`projections`, `queue`, `readers`, …), а не свободной строкой лога. Плагин объявляет по нему
  счётчик `error_metric/2` — `<префикс плагина>_collect_errors_total{collector}`; успешный цикл
  событие не эмитит.

  Счётчик, а не gauge времени последнего успешного сбора: у gauge нет серии, если сбор не удался
  ни разу с запуска ноды (БД недоступна на старте), и алерт на него молчит. Отказ же повторяется
  на каждом опросе, так что счётчик растёт, пока сбор отказывает, — `increase` видит рост со
  второго отказа, и алерт с `for:` поднимается, несмотря на невидимый первый инкремент новой серии.
  """

  require Logger

  # ===== сбор =====

  @doc """
  Выполнить сбор метрик, проглотив исключение и `exit` источника.

  `plugin` — имя плагина в событии отказа (`error_event/1`), `collector` — закрытое имя
  polling-группы для тега, `label` — что собиралось, попадает в лог.
  """
  @spec execute(atom(), atom(), String.t(), (-> any())) :: :ok

  def execute(plugin, collector, label, fun)
      when is_atom(plugin) and is_atom(collector) and is_binary(label) and is_function(fun, 0) do
    _ = fun.()
    :ok
  rescue
    exception ->
      report_skipped(plugin, collector, label, Exception.format(:error, exception, __STACKTRACE__))
  catch
    :exit, reason ->
      report_skipped(plugin, collector, label, "exit reason=#{inspect(reason)}")
  end

  @doc """
  Собрать значения источника, проглотив исключение и `exit`: сбой — `[]`, причина — в лог,
  отказ — событием, как у `execute/4`.

  Для сбора, которому нужен результат (значения одного процесса внутри общего цикла): отказ
  засчитывается группе `collector` общего цикла.
  """
  @spec collect(atom(), atom(), String.t(), (-> list())) :: list()

  def collect(plugin, collector, label, fun)
      when is_atom(plugin) and is_atom(collector) and is_binary(label) and is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      report_skipped(plugin, collector, label, Exception.format(:error, exception, __STACKTRACE__))
      []
  catch
    :exit, reason ->
      report_skipped(plugin, collector, label, "exit reason=#{inspect(reason)}")
      []
  end

  # ---

  defp report_skipped(plugin, collector, label, detail) do
    Logger.warning("PromEx: сбор метрик пропущен (#{label}): #{detail}")
    :telemetry.execute(error_event(plugin), %{count: 1}, %{collector: collector})
  end

  # ===== метрика отказа =====

  @doc """
  Счётчик отказов сбора плагина: `<metric_prefix>.collect.errors.total{collector}`.

  Плагин объявляет его в event-метриках, а не в polling-группе: счётчик есть и тогда, когда
  группа не строится, — серии просто не будет.
  """
  @spec error_metric([atom()], atom()) :: Telemetry.Metrics.Counter.t()

  def error_metric(metric_prefix, plugin) when is_list(metric_prefix) and is_atom(plugin) do
    Telemetry.Metrics.counter(
      metric_prefix ++ [:collect, :errors, :total],
      event_name: error_event(plugin),
      description: "Число отказов сбора polling-метрик: gauge'и группы застыли на прошлом значении",
      tags: [:collector],
      tag_values: &collector_tag_values/1
    )
  end

  @doc "Telemetry-событие отказа сбора плагина: `[:prom_ex, :plugin, plugin, :collect, :error]`."
  @spec error_event(atom()) :: [atom()]

  def error_event(plugin) when is_atom(plugin), do: [:prom_ex, :plugin, plugin, :collect, :error]

  # ---

  defp collector_tag_values(%{collector: collector}), do: %{collector: Atom.to_string(collector)}
end
