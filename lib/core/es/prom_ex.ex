defmodule Core.Es.PromEx do
  @moduledoc """
  PromEx plugin event sourcing: event-метрики восстановления агрегата, записи снапшота, цикла и
  ожидания проекции, процесса агрегата; polling gauges проекций и процессов агрегата.

      {Core.Es.PromEx,
       poll_rate: 5_000,
       projections: {MyApp.Projections, :opts, []},
       processes: {MyApp.PromEx.Es, :processes, []}}

  Event-метрики строятся всегда — по telemetry `[:es, :aggregate, :load]`,
  `[:es, :aggregate, :fold]`, `[:es, :snapshot, :write]`, `[:es, :projection, :cycle]`,
  `[:es, :projection, :await]` и `[:es, :aggregate, :process, :execute | :start | :stop]`
  (`Core.Telemetry.event/1`).

  ## Opts

  - `projections:` — MFA-провайдер опций дерева `Core.Es.Projection.Supervisor`, тот же, что у
    элемента дерева; из опций берётся список `projections:`. Без опции polling-группа проекций не
    строится.
  - `processes:` — MFA-провайдер списка модулей `use Core.Es.Aggregate.Process`. Без опции
    polling-группа процессов не строится.
  - `poll_rate:` — интервал опроса, мс, по умолчанию 5 000
  - `metric_prefix:` — по умолчанию `PromEx.metric_prefix(otp_app, :es)`
  - `duration_unit:` — единица длительностей, по умолчанию `:millisecond`

  ## Polling

  Запросы идут на `Core.Config.dao/0`; сбор — под `Core.PromEx.Safe`: недоступная БД или провайдер
  пропускают цикл, gauge остаётся с прошлым значением.

  - `projection.lag.seconds{projection}` — отставание проекции: возраст самого раннего из первых
    событий типов проекции после чекпоинта (`LIMIT 1` на тип), без условия видимости пачки;
    событий нет — 0; строки чекпоинта нет или её версия ниже `version:` модуля — возраст первого
    события истории.
  - `projection.rebuilding{projection}` — 1: строки чекпоинта нет, её версия ниже `version:` модуля
    или чекпоинт ниже цели пересборки.
  - `projection.outdated{projection}` — 1: версия строки выше `version:` модуля на этой ноде.
  - `checkpoint.orphan{name}` — на каждую строку `es_checkpoints`: 1, если имени нет в
    `projections:` ноды.
  - `aggregate.processes{type}` — процессов на id под `DynamicSupervisor` процесса агрегата
    (`DynamicSupervisor.count_children/1`); дерево не запущено — 0.
  """

  use PromEx.Plugin

  alias Core.Config
  alias Core.Es
  alias Core.Es.Projection.Checkpoint
  alias Core.PromEx.Safe
  alias Core.Telemetry

  @lag_event [:prom_ex, :plugin, :es, :projection, :lag]
  @rebuilding_event [:prom_ex, :plugin, :es, :projection, :rebuilding]
  @outdated_event [:prom_ex, :plugin, :es, :projection, :outdated]
  @orphan_event [:prom_ex, :plugin, :es, :checkpoint, :orphan]
  @processes_event [:prom_ex, :plugin, :es, :aggregate, :processes]

  @duration_buckets [1, 10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
  @events_buckets [0, 1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]

  # ===== метрики событий =====

  @doc false
  @spec event_metrics(keyword()) :: [Event.t()]

  @impl true
  def event_metrics(opts) do
    prefix = metric_prefix(opts)
    unit = Keyword.get(opts, :duration_unit, :millisecond)

    [
      aggregate_event_group(prefix, unit),
      projection_event_group(prefix, unit),
      process_event_group(prefix, unit)
    ]
  end

  # ---

  defp aggregate_event_group(prefix, unit) do
    load = Telemetry.event([:es, :aggregate, :load])
    write = Telemetry.event([:es, :snapshot, :write])
    load_tags = ~w(type op result)a
    fold_tags = ~w(type snapshot)a
    write_tags = ~w(type result)a

    Event.build(:es_aggregate_event_metrics, [
      counter(
        prefix ++ [:aggregate, :load, :total],
        event_name: load,
        description: "Число восстановлений event-sourced агрегата",
        tags: load_tags,
        tag_values: tag_values(load_tags)
      ),
      distribution(
        prefix ++ [:aggregate, :load, :duration, plural(unit)],
        event_name: load,
        measurement: :duration,
        description: "Длительность восстановления event-sourced агрегата",
        reporter_options: [buckets: @duration_buckets],
        tags: load_tags,
        tag_values: tag_values(load_tags),
        unit: {:native, unit}
      ),
      distribution(
        prefix ++ [:aggregate, :fold, :events],
        event_name: Telemetry.event([:es, :aggregate, :fold]),
        measurement: :events,
        description: "Длина свёрнутого хвоста потока агрегата (событий)",
        reporter_options: [buckets: @events_buckets],
        tags: fold_tags,
        tag_values: tag_values(fold_tags)
      ),
      counter(
        prefix ++ [:snapshot, :write, :total],
        event_name: write,
        description: "Число записей снапшотов агрегата",
        tags: write_tags,
        tag_values: tag_values(write_tags)
      ),
      distribution(
        prefix ++ [:snapshot, :write, :duration, plural(unit)],
        event_name: write,
        measurement: :duration,
        description: "Длительность записи снапшотов агрегата",
        reporter_options: [buckets: @duration_buckets],
        tags: write_tags,
        tag_values: tag_values(write_tags),
        unit: {:native, unit}
      ),
      sum(
        prefix ++ [:snapshot, :write, :rows, :total],
        event_name: write,
        measurement: :rows,
        description: "Число записанных строк снапшотов агрегата",
        tags: [:type]
      )
    ])
  end

  defp projection_event_group(prefix, unit) do
    cycle = Telemetry.event([:es, :projection, :cycle])
    await = Telemetry.event([:es, :projection, :await])
    result_tags = ~w(projection result)a

    Event.build(:es_projection_event_metrics, [
      counter(
        prefix ++ [:projection, :cycles, :total],
        event_name: cycle,
        description: "Число циклов читателя проекции",
        tags: result_tags,
        tag_values: tag_values(result_tags)
      ),
      distribution(
        prefix ++ [:projection, :duration, plural(unit)],
        event_name: cycle,
        measurement: :duration,
        description: "Длительность цикла читателя проекции",
        reporter_options: [buckets: @duration_buckets],
        tags: result_tags,
        tag_values: tag_values(result_tags),
        unit: {:native, unit}
      ),
      sum(
        prefix ++ [:projection, :events, :total],
        event_name: cycle,
        measurement: :events,
        description: "Число событий, прочитанных пачками проекции",
        tags: [:projection]
      ),
      counter(
        prefix ++ [:projection, :retry, :total],
        event_name: cycle,
        description: "Число отказов пачки проекции с повтором",
        keep: &match?(%{result: :retry}, &1),
        tags: [:projection, :error]
      ),
      counter(
        prefix ++ [:projection, :await, :total],
        event_name: await,
        description: "Число ожиданий проекции после записи",
        tags: result_tags,
        tag_values: tag_values(result_tags)
      ),
      distribution(
        prefix ++ [:projection, :await, :duration, plural(unit)],
        event_name: await,
        measurement: :duration,
        description: "Длительность ожидания проекции после записи",
        reporter_options: [buckets: @duration_buckets],
        tags: result_tags,
        tag_values: tag_values(result_tags),
        unit: {:native, unit}
      )
    ])
  end

  defp process_event_group(prefix, unit) do
    execute = Telemetry.event([:es, :aggregate, :process, :execute])
    execute_tags = ~w(type mode result)a
    stop_tags = ~w(type reason)a

    Event.build(:es_aggregate_process_event_metrics, [
      counter(
        prefix ++ [:aggregate, :process, :execute, :total],
        event_name: execute,
        description: "Число команд процесса агрегата",
        tags: execute_tags,
        tag_values: tag_values(execute_tags)
      ),
      distribution(
        prefix ++ [:aggregate, :process, :execute, :duration, plural(unit)],
        event_name: execute,
        measurement: :duration,
        description: "Длительность команды процесса агрегата с ожиданием в очереди",
        reporter_options: [buckets: @duration_buckets],
        tags: execute_tags,
        tag_values: tag_values(execute_tags),
        unit: {:native, unit}
      ),
      distribution(
        prefix ++ [:aggregate, :process, :execute, :queue, plural(unit)],
        event_name: execute,
        measurement: :queue,
        description: "Ожидание команды в очереди процесса агрегата на id",
        keep: &match?(%{mode: :process}, &1),
        reporter_options: [buckets: @duration_buckets],
        tags: [:type],
        unit: {:native, unit}
      ),
      sum(
        prefix ++ [:aggregate, :process, :execute, :retries, :total],
        event_name: execute,
        measurement: :retries,
        description: "Число повторов команды после конфликта версии",
        tags: [:type]
      ),
      counter(
        prefix ++ [:aggregate, :process, :start, :total],
        event_name: Telemetry.event([:es, :aggregate, :process, :start]),
        description: "Число стартов процесса агрегата на id",
        tags: [:type]
      ),
      counter(
        prefix ++ [:aggregate, :process, :stop, :total],
        event_name: Telemetry.event([:es, :aggregate, :process, :stop]),
        description: "Число уходов процесса агрегата на id",
        tags: stop_tags,
        tag_values: tag_values(stop_tags)
      )
    ])
  end

  defp plural(unit), do: PromEx.Utils.make_plural_atom(unit)

  defp tag_values(keys),
    do: fn metadata -> Map.new(keys, &{&1, to_string(Map.fetch!(metadata, &1))}) end

  # ===== метрики опроса =====

  @doc false
  @spec polling_metrics(keyword()) :: [Polling.t()]

  @impl true
  def polling_metrics(opts) do
    prefix = metric_prefix(opts)
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    projection_poll_groups(Keyword.get(opts, :projections), prefix, poll_rate) ++
      process_poll_groups(Keyword.get(opts, :processes), prefix, poll_rate)
  end

  # ---

  defp projection_poll_groups(nil, _prefix, _poll_rate), do: []

  defp projection_poll_groups({mod, fun, args} = provider, prefix, poll_rate)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    [
      Polling.build(
        :es_projection_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_projection_metrics, [provider]},
        [
          last_value(
            prefix ++ [:projection, :lag, :seconds],
            event_name: @lag_event,
            description: "Отставание проекции: возраст первого необработанного события (секунды)",
            measurement: :seconds,
            tags: [:projection]
          ),
          last_value(
            prefix ++ [:projection, :rebuilding],
            event_name: @rebuilding_event,
            description: "Проекция пересобирается, read-модель неполна (1) или нет (0)",
            measurement: :value,
            tags: [:projection]
          ),
          last_value(
            prefix ++ [:projection, :outdated],
            event_name: @outdated_event,
            description: "Чекпоинт новее version: проекции на этой ноде (1) или нет (0)",
            measurement: :value,
            tags: [:projection]
          ),
          last_value(
            prefix ++ [:checkpoint, :orphan],
            event_name: @orphan_event,
            description: "Строка es_checkpoints без проекции в списке ноды (1) или с ней (0)",
            measurement: :value,
            tags: [:name]
          )
        ],
        detach_on_error: false
      )
    ]
  end

  defp process_poll_groups(nil, _prefix, _poll_rate), do: []

  defp process_poll_groups({mod, fun, args} = provider, prefix, poll_rate)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    [
      Polling.build(
        :es_aggregate_process_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_process_metrics, [provider]},
        [
          last_value(
            prefix ++ [:aggregate, :processes],
            event_name: @processes_event,
            description: "Число процессов агрегата на id на ноде",
            measurement: :count,
            tags: [:type]
          )
        ],
        detach_on_error: false
      )
    ]
  end

  # ===== замер проекций =====

  @doc false
  @spec execute_projection_metrics({module(), atom(), [term()]}, DateTime.t()) :: :ok

  def execute_projection_metrics({mod, fun, args}, now \\ DateTime.utc_now())
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    Safe.execute("es projections", fn ->
      mod
      |> apply(fun, args)
      |> Keyword.fetch!(:projections)
      |> emit_projection_metrics(now)
    end)
  end

  # ---

  defp emit_projection_metrics(projections, now) do
    dao = Config.dao()
    checkpoints = Map.new(Checkpoint.list(dao))
    declarations = Enum.map(projections, & &1.__es_projection__())
    names = MapSet.new(declarations, & &1.name)

    Enum.each(declarations, &emit_projection(dao, &1, Map.get(checkpoints, &1.name), now))
    Enum.each(Map.keys(checkpoints), &emit_orphan(&1, not MapSet.member?(names, &1)))
  end

  defp emit_projection(dao, declaration, checkpoint, now) do
    metadata = %{projection: declaration.name}
    lag = lag_seconds(dao, declaration, checkpoint, now)
    rebuilding = flag(Checkpoint.rebuilding?(checkpoint, declaration))
    outdated = flag(Checkpoint.outdated?(checkpoint, declaration))

    :telemetry.execute(@lag_event, %{seconds: lag}, metadata)
    :telemetry.execute(@rebuilding_event, %{value: rebuilding}, metadata)
    :telemetry.execute(@outdated_event, %{value: outdated}, metadata)
  end

  defp lag_seconds(dao, declaration, checkpoint, now) do
    position = lag_position(checkpoint, declaration)

    case Es.Store.oldest_at_after(dao, Map.keys(declaration.streams), position) do
      nil -> 0
      at -> max(DateTime.diff(now, at, :second), 0)
    end
  end

  # Строки нет или её версия ниже `version:` — пачка этого кода начнёт с начала истории.
  defp lag_position(nil, _declaration), do: nil
  defp lag_position(%{version: version}, %{version: current}) when version < current, do: nil
  defp lag_position(%{position: position}, _declaration), do: position

  defp emit_orphan(name, orphan?),
    do: :telemetry.execute(@orphan_event, %{value: flag(orphan?)}, %{name: name})

  defp flag(true), do: 1
  defp flag(false), do: 0

  # ===== замер процессов =====

  @doc false
  @spec execute_process_metrics({module(), atom(), [term()]}) :: :ok

  def execute_process_metrics({mod, fun, args})
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    Safe.execute("es processes", fn ->
      mod
      |> apply(fun, args)
      |> Enum.each(&emit_processes/1)
    end)
  end

  # ---

  defp emit_processes(process) do
    %{type: type, supervisor: supervisor} = process.__es_aggregate_process__()
    count = active(Process.whereis(supervisor))

    :telemetry.execute(@processes_event, %{count: count}, %{type: type})
  end

  # Дерево не запущено или отключено — процессов на id на ноде нет.
  defp active(nil), do: 0
  defp active(pid), do: DynamicSupervisor.count_children(pid).active

  # ===== общее =====

  defp metric_prefix(opts),
    do:
      Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(Keyword.fetch!(opts, :otp_app), :es))
end
