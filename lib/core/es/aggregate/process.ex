defmodule Core.Es.Aggregate.Process do
  @moduledoc """
  Билдер процесса агрегата (`use`): кэш состояния и очередь команд одного event-sourced агрегата
  на ноде; команда — с повтором после отказа записи.

      defmodule MyApp.Domain.<BC>.Common.Account.Process do
        use Core.Es.Aggregate.Process,
          repo: MyApp.Domain.<BC>.Common.Account.Repo
      end

      # MyApp.Application
      children = [MyApp.DAO, {MyApp.Domain.<BC>.Common.Account.Process, enabled: true}]

      # usecase
      Account.Process.execute(id, :current, command, context, fn events ->
        enqueue_notifications(events)
      end)

  Генерирует `execute/6`, `child_spec/1` и `watch_list/1`. Реализация `repo:` резолвится
  `Core.Config.repo!/1` по конвенции `<Behaviour>.Pg`.

  ## Команда

  `execute(id, version, command, context, fun, opts)` → `{:ok, Version.t() | nil} |
  {:error, Error.t()}`; `fun` и `opts` необязательны. Одна транзакция `Core.Es.Transact` на
  `Core.Config.dao/0`: состояние агрегата → `Agg.execute/2` → `append(events, context)` →
  `fun.(events)`. Решение идёт через `get_decision(id, version, context, &Agg.execute(&1,
  command))` репозитория; процесс на id дочитывает закэшированный заведённый агрегат
  `refresh(state, version, context)`, а незаведённый — снова через `get_decision`. Колбэк —
  сопутствующие записи (Oban, `DAO`) под ограничениями `Transact.run`, возвращает
  `:ok | {:error, _}`. Ошибка `decide`, `append` или колбэка откатывает транзакцию: отказ
  хранилища повторяется, остальное уходит вызывающему.

  Успех — версия состояния после commit, в том числе после повторов: по ней вызывающий отвечает
  клиенту и шлёт следующий `If-Match`. Команда без событий версию не меняет, на пустом потоке —
  `{:ok, nil}`. Само состояние наружу не уходит.

  Голова принимает только `%Agg.ID{}`, результат сужен паттерном до `{:ok, %Version{}} |
  {:ok, nil} | {:error, _}`: невозможная clause по результату — предупреждение при сборке. Домен
  команды — любой struct: процесс не видит `decide/2` агрегата, и команду другого агрегата сборка
  не ловит.

  - Отказ хранилища — `:version_mismatch` с `source: :storage` в detail — при **любой**
    ожидаемой версии: повтор новой транзакцией (`Core.Es.Transact`), колбэк зовётся заново;
    `debug` на каждый повтор. После `retries:` повторов — `warning` и ошибка вызывающему. Отказ
    приходит и из `append`, и из колбэка (запись в соседний поток), и повторяется одинаково —
    колбэк обязан быть идемпотентным.
  - Колбэк вернул не `:ok | {:error, _}` — `CaseClauseError` до commit, транзакция откатывается.
  - Сверка ожидаемой версии — `:version_mismatch` с `source: :expected` — повтора не даёт
    никогда: `%Version{}` мимо головы непустого потока из `get_decision` или `refresh`, клиент
    видел устаревшее состояние, и повтор его не исправит.
  - `%Version{}` на пустом потоке (ADR-0016) — ошибка `decide`, если он команду отклоняет, и
    `:version_mismatch` с `actual: nil`, если принимает, в том числе без событий: без `append`,
    колбэка и повтора.
  - Вызов внутри транзакции — `ArgumentError`: команда идёт своей транзакцией, и откат попытки
    отменил бы внешнюю.
  - Нет отметки старта — `RuntimeError`: `{Agg.Process, opts}` не стоит в дереве супервизии.
  - `opts` — `timeout:`, положительное целое, по умолчанию 5 000 мс: дедлайн команды процесса на
    id, в вызывающем процессе не действует; неизвестная опция или недопустимое значение —
    `ArgumentError`.

  ## Процесс на id

  При `enabled: true` команды агрегата идут по одной в его процесс
  (`Core.Es.Aggregate.Process.Server`), колбэк исполняется там же. Процесс держит состояние
  агрегата после последнего commit, и это кэш: корректность держат проверки `append`. Второй
  процесс того же агрегата (другая нода) и запись в обход процесса штатны — их события дочитает
  `refresh`, а гонку на записи снимет повтор после отказа хранилища.

  - Старт — лениво в первой команде, без запросов: имени id в `Registry` дерева нет (`:noproc`) —
    процесс стартует под `DynamicSupervisor`, и вызов повторяется один раз. Процесс, ушедший по
    простою, не приняв команду, — тот же повтор.
  - Окружение вызывающего — только на время команды: OTel-контекст, `Logger.metadata()` и
    `context`, в котором `:shadow_copy` заменён собственной таблицей `Core.Repo.Sc` процесса:
    приватная ETS вызывающего процессу недоступна. `context` между командами не хранится.
  - `timeout:` — дедлайн: команда, простоявшая в очереди до дедлайна, отбрасывается до
    транзакции; дедлайн, истёкший до commit, откатывает транзакцию; попытка после дедлайна не
    идёт — повтор после отказа записи обрывается, не читая и не записывая. Вызывающему по
    истечении — exit `GenServer.call`, как и при падении процесса.
  - Исключение в `decide`, `evolve` или колбэке роняет процесс: транзакция откатывается,
    вызывающему — exit. Процессы `restart: :temporary` — следующая команда стартует новый.
  - Простой `idle_timeout:` — уход `{:stop, :normal}`; снапшот при уходе не пишется.
  - Остановка дерева ждёт команду, которую процесс исполняет, до 10 000 мс: процесс ставит
    `trap_exit`, и команда не обрывается посреди транзакции.

  ## Старт

  `child_spec(opts)` — элемент дерева потребителя; опции проверяются при старте
  (`Core.Helper.StartOpts`), недопустимая — `ArgumentError`.

  - `enabled:` — обязательна. `true` — `Supervisor` под именем модуля процесса, `rest_for_one`:
    `Registry` процессов на id (единственность — на ноду) и их `DynamicSupervisor`; `info`
    «запущен» и отметка опций в `:persistent_term`. `false` — `:ignore`, `info` «отключён» и
    отметка: `execute` исполняет команду в вызывающем процессе.
  - `retries:` — повторов после отказа записи, по умолчанию 3
  - `idle_timeout:` — мс простоя процесса на id до ухода, по умолчанию 60 000

  Числа — положительные целые.

  `watch_list(opts)` — элементы `watch:` плагина `Core.Workers.PromEx` по опциям старта: верхний
  супервизор, `%{component: "es_aggregate_process:<тип агрегата>", name: Agg.Process}`. При
  `enabled: false` элементов нет: дерева на ноде нет, и `up=0` был бы ложной тревогой.

  ## Наблюдаемость

  - Span `execute <тип агрегата>` — `Core.Otel.Es.execute/4` в процессе вызывающего: охватывает и
    ожидание в очереди процесса на id, выход из неё — span event `dequeued`.
  - Telemetry `[:es, :aggregate, :process, :execute]` у вызывающего на вызов: измерения `duration`
    (native), `queue` (native, ожидание в очереди; в вызывающем процессе — 0), `retries`;
    метаданные `type` (тип агрегата), `mode` (`:process`, `:inline`), `result` (`:ok`,
    `:version_mismatch`, `:error`, `:exit` — exit вызывающему, `queue` и `retries` — 0). Код
    доменной ошибки в метаданные не идёт; исключения у вызывающего telemetry не шлют.
  - `[:es, :aggregate, :process, :start]` — старт процесса на id, `[:es, :aggregate, :process,
    :stop]` — его уход: измерений нет, метаданные `type`, у `:stop` — `reason` (`:idle`, `:error`
    — исключение). `debug` на старт и уход по простою, `warning` на отброшенную просроченную
    команду.

  ## Opts

  - `repo:` — behaviour write-репозитория агрегата (`use Core.Es.Aggregate.Repo`)

  На компиляции `CompileError`, если `repo:` — не behaviour `use Core.Es.Aggregate.Repo`, у
  кодека событий агрегата нет `type:` или реализация репозитория недоступна.

  Макрос занимает в вызывающем модуле имя `@es_aggregate_process`, а на ноде — имена процессов
  `<Agg.Process>.Registry` и `<Agg.Process>.Supervisor`.
  """

  import Core.Version, only: [is_version: 1]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Process.Execution
  alias Core.Es.Aggregate.Process.Server
  alias Core.Helper
  alias Core.Helper.StartOpts
  alias Core.Otel
  alias Core.Telemetry
  alias Core.Version

  require Logger

  @label "Es.Aggregate.Process"
  @required_keys ~w(repo)a
  @optional_keys []
  @execute_defaults [timeout: 5_000]
  @start_defaults [retries: 3, idle_timeout: 60_000]

  @typedoc "Проверенные опции старта — они же отметка."
  @type options :: %{enabled: boolean(), retries: pos_integer(), idle_timeout: pos_integer()}

  @typedoc "Объявление `use`: реализация репозитория, агрегат, его тип и имена процессов дерева."
  @type cfg :: %{
          repo: module(),
          aggregate: module(),
          type: String.t(),
          registry: atom(),
          supervisor: atom()
        }

  @typedoc "Вызов `execute`: адрес агрегата, команда, контекст и колбэк."
  @type call :: %{
          id: struct(),
          version: Version.expected(),
          command: struct(),
          context: Context.t(),
          fun: ([Es.Event.t()] -> :ok | {:error, Error.t()}) | nil
        }

  @typedoc "Элемент `watch:` плагина `Core.Workers.PromEx`."
  @type watch_item :: %{component: String.t(), name: module()}

  # ===== объявление =====

  @doc "Объявить процесс event-sourced агрегата."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    behaviour = Helper.Opts.module!(lit, :repo, @label, exports: [__es_aggregate_repo__: 0])
    %{aggregate: aggregate, id: id} = behaviour.__es_aggregate_repo__()
    type = Es.Store.Opts.event_codec!(aggregate.__es_event_codec__(), @label).__es_type__()
    process = __CALLER__.module

    quote generated: true do
      import Core.Version, only: [is_version: 1]

      require Core.Config

      @es_aggregate_process %{
        repo: Core.Config.repo!(unquote(behaviour)),
        aggregate: unquote(aggregate),
        type: unquote(type),
        registry: unquote(child_name(process, "Registry")),
        supervisor: unquote(child_name(process, "Supervisor"))
      }

      @doc """
      Исполнить команду агрегата одной транзакцией: состояние → `execute/2` → `append` →
      `fun.(events)`; отказ хранилища повторяется. Успех — версия после commit.
      """
      @spec execute(
              unquote(id).t(),
              Core.Version.expected(),
              struct(),
              Core.Context.t(),
              ([Core.Es.Event.t()] -> :ok | {:error, Core.Error.t()}) | nil,
              keyword()
            ) :: {:ok, Core.Version.t() | nil} | {:error, Core.Error.t()}

      def execute(
            %unquote(id){} = id,
            version,
            command,
            %Core.Context{} = context,
            fun \\ nil,
            opts \\ []
          )
          when is_version(version) and is_struct(command) and
                 (is_nil(fun) or is_function(fun, 1)) and is_list(opts) do
        call = %{id: id, version: version, command: command, context: context, fun: fun}

        case Core.Es.Aggregate.Process.execute(__MODULE__, @es_aggregate_process, call, opts) do
          {:ok, %Core.Version{} = version} -> {:ok, version}
          {:ok, nil} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end

      @doc "Элемент дерева супервизии: `{#{inspect(__MODULE__)}, enabled: …}`."
      @spec child_spec(keyword()) :: Supervisor.child_spec()

      def child_spec(opts) when is_list(opts),
        do: Core.Es.Aggregate.Process.child_spec(__MODULE__, @es_aggregate_process, opts)

      @doc """
      Элементы `watch:` плагина `Core.Workers.PromEx` по опциям старта; при `enabled: false` —
      `[]`.
      """
      @spec watch_list(keyword()) :: [Core.Es.Aggregate.Process.watch_item()]

      def watch_list(opts) when is_list(opts),
        do: Core.Es.Aggregate.Process.watch_list(__MODULE__, @es_aggregate_process, opts)

      @doc false
      @spec __es_aggregate_process__() :: Core.Es.Aggregate.Process.cfg()

      def __es_aggregate_process__, do: @es_aggregate_process
    end
  end

  # ---

  # Имена `Registry` и `DynamicSupervisor` дерева вычисляются на компиляции из имени модуля
  # процесса: `safe_concat` непригоден — это имена процессов, а не модулей, и атомов их ещё нет.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp child_name(process, suffix), do: Module.concat(process, suffix)

  # ===== команда =====

  @doc false
  @spec execute(module(), cfg(), call(), keyword()) ::
          {:ok, Version.t() | nil} | {:error, Error.t()}

  def execute(process, cfg, call, opts) when is_atom(process) and is_list(opts) do
    timeout = timeout!(opts)
    ensure_outside_transaction!(Config.dao().in_transaction?(), process)
    options = started!(mark(process), process)
    mode = mode(options)

    target = %{
      aggregate_id: Config.codec().dump(call.id),
      limit: options.retries,
      deadline: deadline(mode, timeout)
    }

    Otel.Es.execute(cfg.type, target.aggregate_id, call.command.__struct__, fn ->
      measured(cfg, mode, fn -> dispatch(mode, cfg, options, call, target) end)
    end)
  end

  # ---

  defp timeout!(opts) do
    case Keyword.validate!(opts, @execute_defaults) do
      [timeout: timeout] when is_integer(timeout) and timeout > 0 ->
        timeout

      [timeout: timeout] ->
        raise ArgumentError,
              "#{@label}: опция :timeout — ожидается положительное целое, получено " <>
                inspect(timeout)
    end
  end

  defp ensure_outside_transaction!(false, _process), do: :ok

  defp ensure_outside_transaction!(true, process) do
    raise ArgumentError,
          "#{@label}: #{inspect(process)}.execute вызван внутри транзакции — команда идёт " <>
            "своей транзакцией, и откат попытки отменил бы внешнюю"
  end

  defp started!(nil, process) do
    raise "#{@label}: #{inspect(process)} не запущен — нет отметки старта: " <>
            "{#{inspect(process)}, opts} не стоит в дереве супервизии"
  end

  defp started!(%{} = options, _process), do: options

  defp mode(%{enabled: true}), do: :process
  defp mode(%{enabled: false}), do: :inline

  defp deadline(:process, timeout), do: System.monotonic_time(:millisecond) + timeout
  defp deadline(:inline, _timeout), do: nil

  # Exit вызывающему — тоже исход вызова: telemetry уходит, а exit летит дальше как был.
  defp measured(cfg, mode, fun) do
    start = System.monotonic_time()

    try do
      fun.()
    catch
      :exit, reason ->
        emit_execute(cfg, mode, :exit, measurements(start, 0, 0))
        :erlang.raise(:exit, reason, __STACKTRACE__)
    else
      {result, retries, queue} ->
        :ok = Otel.Es.executed(mode, retries)
        emit_execute(cfg, mode, result_tag(result), measurements(start, queue, retries))
        result
    end
  end

  defp dispatch(:inline, cfg, _options, call, target) do
    {outcome, retries} = Execution.run(cfg, call, target, nil)
    {Execution.result(outcome), retries, 0}
  end

  defp dispatch(:process, cfg, options, call, target),
    do: Server.execute(cfg, options, call, target)

  defp measurements(start, queue, retries),
    do: %{duration: System.monotonic_time() - start, queue: queue, retries: retries}

  defp emit_execute(cfg, mode, result, measurements) do
    :telemetry.execute(
      Telemetry.event([:es, :aggregate, :process, :execute]),
      measurements,
      %{type: cfg.type, mode: mode, result: result}
    )
  end

  defp result_tag({:ok, _version}), do: :ok
  defp result_tag({:error, %Error{code: :version_mismatch}}), do: :version_mismatch
  defp result_tag({:error, _error}), do: :error

  # ===== запуск =====

  @doc false
  @spec child_spec(module(), cfg(), keyword()) :: Supervisor.child_spec()

  def child_spec(process, cfg, opts) when is_atom(process) and is_list(opts),
    do: %{id: process, start: {__MODULE__, :start_link, [process, cfg, opts]}, type: :supervisor}

  @doc false
  @spec start_link(module(), cfg(), keyword()) :: Supervisor.on_start()

  def start_link(process, cfg, opts) when is_atom(process) and is_list(opts),
    do: start(process, cfg, options!(opts))

  @doc false
  @spec watch_list(module(), cfg(), keyword()) :: [watch_item()]

  def watch_list(process, cfg, opts) when is_atom(process) and is_list(opts) do
    case options!(opts) do
      %{enabled: false} -> []
      %{enabled: true} -> [%{component: "es_aggregate_process:#{cfg.type}", name: process}]
    end
  end

  @doc false
  @spec mark(module()) :: options() | nil

  def mark(process) when is_atom(process), do: :persistent_term.get(mark_key(process), nil)

  # ---

  defp options!(opts) do
    enabled = StartOpts.boolean!(@label, opts, :enabled)

    @start_defaults
    |> Map.new(fn {key, default} -> {key, StartOpts.pos_integer!(@label, opts, key, default)} end)
    |> Map.put(:enabled, enabled)
  end

  defp start(process, cfg, %{enabled: false} = options) do
    :persistent_term.put(mark_key(process), options)
    Logger.info("процесс агрегата: отключён: type=#{cfg.type}")
    :ignore
  end

  defp start(process, cfg, %{enabled: true} = options) do
    children = [
      {Registry, keys: :unique, name: cfg.registry},
      {DynamicSupervisor, name: cfg.supervisor, strategy: :one_for_one}
    ]

    with {:ok, _pid} = started <-
           Supervisor.start_link(children, strategy: :rest_for_one, name: process) do
      :persistent_term.put(mark_key(process), options)
      Logger.info("процесс агрегата: запущен: type=#{cfg.type}")
      started
    end
  end

  defp mark_key(process), do: {__MODULE__, process}
end
