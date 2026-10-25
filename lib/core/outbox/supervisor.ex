defmodule Core.Outbox.Supervisor do
  @moduledoc """
  Дерево очереди outbox: порядок детей и проверки старта держатся построением. Одно на ноду; свой
  супервизор очереди у приложения — `MUST NOT` (`docs/adr/0045-outbox-ready-tree.md`).

      children = [
        MyApp.Infra.DAO,
        {Core.Outbox.Supervisor,
         enabled: true,
         cluster_query: nil,
         connection: {Core.Mq.Stream.Connection, name: MyAppApp.Outbox.Connection},
         pollers: [
           [
             name: MyAppApp.Outbox.Poller,
             label: "stream",
             writer:
               {Core.Mq.Stream.Writer,
                connection: MyAppApp.Outbox.Connection,
                reference_prefix: "my_app-outbox",
                name: MyAppApp.Outbox.Writer}
           ]
         ],
         poll_interval_ms: 1_000,
         idle_min_ms: 50,
         batch_size: 100,
         lock_duration_seconds: 30,
         max_attempts: 10,
         published_ttl_seconds: 604_800,
         cleaner_interval_ms: 3_600_000}
      ]

  Внутри — `rest_for_one`: соединение (если задано) → на каждый элемент `pollers:` в его порядке
  writer-процесс (если задан `writer:`) и `Core.Outbox.Poller` → `Core.Outbox.Cleaner` под именем
  своего модуля. Падение writer'а перезапускает его поллер и всё, что стартовало позже.

  ## Опции

  Состав, типы и умолчания — раздел «Опции» у `start_link/1`; те же опции принимает `watch_list/1`.
  Выключенному дереву нужна только `enabled:`, остальные обязательные — при `enabled: true`; `nil`
  у числовой опции — то же, что её отсутствие (незаданный env выключенной очереди).
  Репозиторий очереди у поллеров и cleaner — тот же, которым пишут записи,
  `Core.Config.outbox_repo/0`: второй источник разошёлся бы с ним молча.

  Числа — положительные целые; в Prim (`Core.Outbox.BatchSize`, `LockDuration`, `Attempts`,
  `PublishedTTL`) их оборачивает дерево. Имена процессов дерева и метки поллеров MUST различаться.
  Доставку поллера дерево собирает само — `Core.Outbox.Delivery.Mq` над writer'ом элемента. Config
  и env библиотека не читает: опции собирает одна функция приложения, её же принимает
  `watch_list/1`.

  ## Старт

  `start_link/1` проверяет опции: неизвестная опция и значение не той формы — `ArgumentError` при
  любом `enabled:`; отсутствующая опция, оба или ни одного из `writer:` / `via:`, повтор имени или
  метки, `enabled: true` при `pollers: []` — `ArgumentError` включённого дерева. Имена переданных
  `pollers:` выключенного дерева уходят в лог. Затем две проверки старта:

  - единственность на кластере: включённая очередь вместе с кластеризацией — `ArgumentError`,
    каждая нода подняла бы свои поллеры; `allow_cluster: true` — старт с `warning`;
  - непересечение фильтров поллеров: два поллера с общим топиком разложили бы его в брокер
    вперемешку — `ArgumentError`. Полнота разбиения не проверяется: топики вне фильтров ждут в
    `pending`, так выключается транспорт.

  После проверок `enabled: false` — `:ignore`, `info` «отключён»; иначе дерево стартует, `info`
  «запущен»; второе дерево на ноде не стартует — имя супервизора занято.

  ## Wake

  До подъёма детей, в том числе при `:ignore`, старт ставит отметку в `:persistent_term`: имена и
  фильтры топиков поллеров дерева, при `:ignore` — пусто. Включённое дерево ставит её в `init/1`,
  после регистрации имени: второе дерево на ноде отметку работающего не перезапишет.
  `Core.Outbox.Repo.Pg` после вставки будит по ней поллеры, чей фильтр совпал с топиками записей;
  нода без дерева или с выключенным деревом не будит никого — записи её вставок поллеры находят
  опросом. `Core.Outbox.Poller` без своего имени в
  отметке не стартует: поднимать его — дело дерева.
  """

  use Supervisor
  use Core.Options

  alias Core.Config
  alias Core.Context
  alias Core.Helper.StartOpts
  alias Core.Outbox
  alias Core.Outbox.Cleaner
  alias Core.Outbox.Delivery
  alias Core.Outbox.Poller
  alias Core.Outbox.Supervisor.Mark
  alias Core.Result

  require Logger

  @start_label "#{inspect(__MODULE__)}.start_link/1"
  @watch_label "#{inspect(__MODULE__)}.watch_list/1"
  @required_when_enabled ~w(
    poll_interval_ms idle_min_ms batch_size lock_duration_seconds max_attempts published_ttl_seconds
    cleaner_interval_ms
  )a

  @poller_opts_schema [
    name: [
      type: {:custom, StartOpts, :atom, []},
      type_doc: "`t:atom/0`",
      required: true,
      doc: "Имя процесса поллера."
    ],
    label: [
      type: {:custom, StartOpts, :binary, []},
      type_doc: "`t:String.t/0`",
      required: true,
      doc: "Непустая метка компонента в `watch_list/1`."
    ],
    topics: [
      type: {:custom, StartOpts, :topics_filter, []},
      type_doc: "`t:Core.Outbox.topics_filter/0`",
      default: :all,
      doc: "Топики записей, которые доставляет поллер."
    ],
    writer: [
      type: {:tuple, [{:custom, StartOpts, :module, []}, :keyword_list]},
      type_doc: "`{module(), keyword()}`",
      doc:
        "Writer-процесс `{модуль Mq.Writer, опции с name: атомом}`: дерево поднимает его перед поллером, " <>
          "поллер пишет через его `name:`. Ровно один из `writer:` и `via:`."
    ],
    via: [
      type: {:tuple, [{:custom, StartOpts, :module, []}, {:custom, StartOpts, :term, []}]},
      type_doc: "`{module(), term()}`",
      doc:
        "`{модуль Mq.Writer, handle}` — процесс, которым владеет приложение (клиент Kafka): дерево его не " <>
          "поднимает и не наблюдает."
    ]
  ]

  @tree_opts_schema [
    enabled: [type: :boolean, required: true, doc: "`false` — дерево не стартует, и прочие опции не нужны."],
    cluster_query: [
      type: {:or, [:string, {:in, [nil, :ignore]}]},
      type_doc: "`t:cluster_query/0`",
      doc: "При `enabled: true` обязательна, без умолчания: запрос кластеризации."
    ],
    allow_cluster: [type: :boolean, default: false, doc: "Разрешить старт включённой очереди в кластере."],
    pollers: [
      type: {:list, {:keyword_list, @poller_opts_schema}},
      default: [],
      doc: "При `enabled: true` — непустой; поллеры, элемент — keyword:\n\n" <> Core.Options.docs(@poller_opts_schema)
    ],
    connection: [
      type: {:or, [{:tuple, [{:custom, StartOpts, :module, []}, :keyword_list]}, nil]},
      type_doc: "`{module(), keyword()}` или `nil`",
      default: nil,
      doc: "`{модуль, опции с name: атомом}`, первый ребёнок дерева: соединение, других пользователей у которого нет."
    ],
    context_factory: [
      type: {:fun, 0},
      default: &Context.new/0,
      doc: "Фабрика `Core.Context`, одна на поллеры и cleaner."
    ],
    poll_interval_ms: [
      type: {:or, [:pos_integer, nil]},
      type_doc: "`t:pos_integer/0` или `nil`",
      doc: "При `enabled: true` обязательна; потолок backoff поллера, мс."
    ],
    idle_min_ms: [
      type: {:or, [:pos_integer, nil]},
      type_doc: "`t:pos_integer/0` или `nil`",
      doc: "При `enabled: true` обязательна; первая пауза backoff поллера, мс."
    ],
    batch_size: [
      type: {:or, [{:custom, __MODULE__, :prim, [Outbox.BatchSize]}, nil]},
      type_doc: "`t:pos_integer/0` или `nil`",
      doc: "При `enabled: true` обязательна; пачка поллера."
    ],
    lock_duration_seconds: [
      type: {:or, [{:custom, __MODULE__, :prim, [Outbox.LockDuration]}, nil]},
      type_doc: "`t:pos_integer/0` или `nil`",
      doc: "При `enabled: true` обязательна; аренда пачки, с."
    ],
    max_attempts: [
      type: {:or, [{:custom, __MODULE__, :prim, [Outbox.Attempts]}, nil]},
      type_doc: "`t:pos_integer/0` или `nil`",
      doc: "При `enabled: true` обязательна; попытки доставки записи."
    ],
    published_ttl_seconds: [
      type: {:or, [{:custom, __MODULE__, :prim, [Outbox.PublishedTTL]}, nil]},
      type_doc: "`t:pos_integer/0` или `nil`",
      doc: "При `enabled: true` обязательна; сколько хранится опубликованная запись, с."
    ],
    cleaner_interval_ms: [
      type: {:or, [:pos_integer, nil]},
      type_doc: "`t:pos_integer/0` или `nil`",
      doc: "При `enabled: true` обязательна; интервал cleaner, мс."
    ]
  ]

  @typedoc "DNS-запрос кластеризации: `nil`, `:ignore` и `\"\"` — кластеризации нет."
  @type cluster_query :: String.t() | :ignore | nil

  @typedoc "Процесс, который поднимает дерево: модуль, его опции и имя."
  @type process :: StartOpts.process()

  @typedoc "Поллер: writer-процесс дерева (`nil` при `via:`) и handle, через который он пишет."
  @type poller :: %{
          name: atom(),
          label: String.t(),
          topics: Outbox.topics_filter(),
          writer: process() | nil,
          via: {module(), term()}
        }

  @typedoc "Проверенные опции дерева: выключенному нужны только поллеры для лога."
  @type options :: %{enabled: false, pollers: [poller()]} | enabled_options()

  @typedoc "Проверенные опции включённого дерева."
  @type enabled_options :: %{
          enabled: true,
          cluster_query: cluster_query(),
          allow_cluster: boolean(),
          pollers: [poller()],
          connection: process() | nil,
          context_factory: (-> Context.t()),
          poll_interval_ms: pos_integer(),
          idle_min_ms: pos_integer(),
          batch_size: Outbox.BatchSize.t(),
          lock_duration: Outbox.LockDuration.t(),
          max_attempts: Outbox.Attempts.t(),
          published_ttl: Outbox.PublishedTTL.t(),
          cleaner_interval_ms: pos_integer()
        }

  @typedoc "Элемент `watch:` плагина `Core.Workers.PromEx`."
  @type watch_item :: %{component: String.t(), name: atom()}

  # ===== старт =====

  @doc "Спецификация ребёнка супервизора: `id` — модуль, дерево — одно на ноду."
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @opts_schema @tree_opts_schema
  @doc "Запустить дерево очереди; `:ignore` — дерево отключено."
  @spec start_link(keyword()) :: Supervisor.on_start()

  def start_link(opts) when is_list(opts) do
    options = options!(opts, @start_label)
    :ok = singleton!(options)
    :ok = partition!(options.pollers)
    start(options)
  end

  # ---

  defp singleton!(%{enabled: false}), do: :ok
  defp singleton!(%{cluster_query: query}) when query in [nil, :ignore, ""], do: :ok

  defp singleton!(%{allow_cluster: true, cluster_query: query}) do
    Logger.warning(
      "супервизор очереди outbox: старт в кластере по allow_cluster: true (OUTBOX_ALLOW_CLUSTER=true), " <>
        "порядок доставки между нодами не гарантирован: cluster_query=#{inspect(query)}"
    )

    :ok
  end

  defp singleton!(%{cluster_query: query}) do
    raise ArgumentError,
          "#{@start_label}: очередь включена вместе с кластеризацией cluster_query=#{inspect(query)}: " <>
            "каждая нода поднимет свои поллеры, и порядок доставки нарушится. " <>
            "Оставьте OUTBOX_ENABLED=true на одном инстансе без DNS_CLUSTER_QUERY либо, если порядок " <>
            "не важен, передайте allow_cluster: true (OUTBOX_ALLOW_CLUSTER=true) " <>
            "(deps/core/docs/rules/app/14-events-outbox.md, «Единственность поллера»)"
  end

  defp partition!(pollers) do
    case overlapping_pair(pollers) do
      nil -> :ok
      {a, b} -> raise ArgumentError, partition_error(a, b)
    end
  end

  defp overlapping_pair(pollers) do
    pollers
    |> pairs()
    |> Enum.find(fn {a, b} -> Outbox.topics_overlap?(a.topics, b.topics) end)
  end

  defp pairs([]), do: []
  defp pairs([head | tail]), do: Enum.map(tail, &{head, &1}) ++ pairs(tail)

  defp partition_error(a, b) do
    "#{@start_label}: фильтры топиков поллеров пересекаются, порядок доставки не гарантирован: " <>
      "#{inspect(a.name)} #{inspect(a.topics)} и #{inspect(b.name)} #{inspect(b.topics)}. " <>
      "Разведите топики по поллерам через {:only, [...]} без общих элементов " <>
      "(deps/core/docs/rules/14-events-outbox.md, «Единственность поллера»)"
  end

  defp start(%{enabled: false, pollers: pollers}) do
    :ok = Mark.put([])
    Logger.info("супервизор очереди outbox: отключён: pollers=#{names(pollers)}")
    :ignore
  end

  defp start(%{pollers: pollers} = options) do
    with {:ok, _pid} = started <- Supervisor.start_link(__MODULE__, options, name: __MODULE__) do
      Logger.info("супервизор очереди outbox: запущен: pollers=#{names(pollers)}")
      started
    end
  end

  defp names(pollers), do: Enum.map_join(pollers, ",", &inspect(&1.name))

  # ===== дети =====

  @doc false
  @spec init(enabled_options()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}

  @impl true
  def init(%{connection: connection, pollers: pollers} = options) do
    :ok = Mark.put(Enum.map(pollers, &{&1.name, &1.topics}))

    children =
      process_children(connection) ++ Enum.flat_map(pollers, &poller_children(&1, options)) ++ [cleaner_child(options)]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # ---

  defp process_children(nil), do: []

  defp process_children(%{module: module, opts: opts, name: name}),
    do: [Supervisor.child_spec({module, opts}, id: name)]

  defp poller_children(%{writer: writer} = poller, options) do
    process_children(writer) ++ [{Poller, poller_opts(poller, options)}]
  end

  defp poller_opts(%{name: name, topics: topics, via: {module, handle}}, options) do
    [
      name: name,
      topics: topics,
      repo: Config.outbox_repo(),
      delivery_module: Delivery.Mq,
      delivery: Delivery.Mq.new(module, handle),
      poll_interval_ms: options.poll_interval_ms,
      idle_min_ms: options.idle_min_ms,
      batch_size: options.batch_size,
      lock_duration: options.lock_duration,
      max_attempts: options.max_attempts,
      context_factory: options.context_factory
    ]
  end

  defp cleaner_child(options) do
    {Cleaner,
     name: Cleaner,
     repo: Config.outbox_repo(),
     published_ttl: options.published_ttl,
     interval_ms: options.cleaner_interval_ms,
     context_factory: options.context_factory}
  end

  # ===== watch_list =====

  @opts_schema @tree_opts_schema
  @doc """
  Элементы `watch:` плагина `Core.Workers.PromEx` — процессы дерева в порядке старта:
  `component: "outbox_connection"`, `"outbox_writer:<label>"` (только у `writer:`),
  `"outbox_poller:<label>"`, `"outbox_cleaner"`.

  Процесс из `via:` наблюдает его владелец. `opts` — опции дерева, проверяются как в
  `start_link/1`. При `enabled: false` элементов нет: процессов на ноде нет, и `up=0` был бы ложной
  тревогой.
  """
  @spec watch_list(keyword()) :: [watch_item()]

  def watch_list(opts) when is_list(opts) do
    case options!(opts, @watch_label) do
      %{enabled: false} ->
        []

      %{connection: connection, pollers: pollers} ->
        connection_items(connection) ++ Enum.flat_map(pollers, &poller_items/1) ++ [cleaner_item()]
    end
  end

  # ---

  defp connection_items(nil), do: []
  defp connection_items(%{name: name}), do: [%{component: "outbox_connection", name: name}]

  defp poller_items(%{name: name, label: label, writer: writer}) do
    writer_items(writer, label) ++ [%{component: "outbox_poller:#{label}", name: name}]
  end

  defp writer_items(nil, _label), do: []
  defp writer_items(%{name: name}, label), do: [%{component: "outbox_writer:#{label}", name: name}]

  defp cleaner_item, do: %{component: "outbox_cleaner", name: Cleaner}

  # ===== проверка опций =====

  @doc false
  @spec prim(term(), module()) :: Result.t(struct(), String.t())

  def prim(value, mod) when is_integer(value) and is_atom(mod) do
    case mod.new(value) do
      {:ok, prim} -> {:ok, prim}
      {:error, _reason} -> invalid_prim(value, mod)
    end
  end

  def prim(value, mod) when is_atom(mod), do: invalid_prim(value, mod)

  # ---

  defp invalid_prim(value, mod), do: {:error, "ожидается целое значение #{inspect(mod)}, получено #{inspect(value)}"}

  # ===== общее =====

  defp options!(opts, label), do: options!(Keyword.fetch!(opts, :enabled), opts, label)

  defp options!(false, opts, label), do: %{enabled: false, pollers: pollers!(Keyword.fetch!(opts, :pollers), label)}

  defp options!(true, opts, label) do
    :ok = required!(opts, label)
    pollers = pollers!(Keyword.fetch!(opts, :pollers), label)
    connection = connection!(Keyword.fetch!(opts, :connection), label)
    ensure_pollers!(pollers, label)

    StartOpts.unique!(
      label,
      :pollers,
      "имена процессов без повторов: имя — id ребёнка",
      process_names(connection, pollers)
    )

    StartOpts.unique!(
      label,
      :pollers,
      "label: без повторов: по метке строится компонент",
      Enum.map(pollers, & &1.label)
    )

    %{
      enabled: true,
      cluster_query: Keyword.fetch!(opts, :cluster_query),
      allow_cluster: Keyword.fetch!(opts, :allow_cluster),
      pollers: pollers,
      connection: connection,
      context_factory: Keyword.fetch!(opts, :context_factory),
      poll_interval_ms: Keyword.fetch!(opts, :poll_interval_ms),
      idle_min_ms: Keyword.fetch!(opts, :idle_min_ms),
      batch_size: Keyword.fetch!(opts, :batch_size),
      lock_duration: Keyword.fetch!(opts, :lock_duration_seconds),
      max_attempts: Keyword.fetch!(opts, :max_attempts),
      published_ttl: Keyword.fetch!(opts, :published_ttl_seconds),
      cleaner_interval_ms: Keyword.fetch!(opts, :cleaner_interval_ms)
    }
  end

  # Незаданное значение (`nil` из пустого env) — то же, что отсутствие: выключенному дереву оно не
  # нужно, а включённому его недостаёт. У `cluster_query:` `nil` — значение, поэтому только наличие.
  defp required!(opts, label) do
    query = if Keyword.has_key?(opts, :cluster_query), do: [], else: [:cluster_query]

    case query ++ Enum.filter(@required_when_enabled, &is_nil(Keyword.get(opts, &1))) do
      [] -> :ok
      missing -> raise ArgumentError, "#{label}: enabled: true — нет обязательных опций #{inspect(missing)}"
    end
  end

  defp ensure_pollers!([], label) do
    raise ArgumentError, "#{label}: enabled: true при pollers: [] — очереди нечем доставлять записи"
  end

  defp ensure_pollers!(_pollers, _label), do: :ok

  defp pollers!(pollers, label), do: Enum.map(pollers, &poller!(&1, label))

  defp poller!(poller, label) do
    {writer, via} = transport!(poller, label)

    %{
      name: Keyword.fetch!(poller, :name),
      label: Keyword.fetch!(poller, :label),
      topics: Keyword.fetch!(poller, :topics),
      writer: writer,
      via: via
    }
  end

  defp transport!(poller, label) do
    case {Keyword.fetch(poller, :writer), Keyword.fetch(poller, :via)} do
      {{:ok, spec}, :error} ->
        %{module: module, name: name} = writer = StartOpts.process!(label, :writer, spec)
        {writer, {module, name}}

      {:error, {:ok, via}} ->
        {nil, via}

      _both_or_none ->
        raise ArgumentError,
              "#{label}: поллеру #{inspect(Keyword.fetch!(poller, :name))} нужен ровно один из writer: и via:, " <>
                "получено #{inspect(poller)}"
    end
  end

  defp connection!(nil, _label), do: nil
  defp connection!(spec, label), do: StartOpts.process!(label, :connection, spec)

  defp process_names(connection, pollers) do
    processes = [connection | Enum.map(pollers, & &1.writer)]
    [Cleaner | for(%{name: name} <- processes, do: name)] ++ Enum.map(pollers, & &1.name)
  end
end
