defmodule Core.Outbox.Supervisor do
  @moduledoc """
  Дерево очереди outbox: порядок детей и проверки старта держатся построением. Одно на ноду; свой
  супервизор очереди у приложения — `MUST NOT` (`docs/adr/0045-outbox-ready-tree.md`).

      children = [
        MyApp.Infra.DAO,
        {Core.Outbox.Supervisor,
         enabled: true,
         cluster_query: nil,
         repo: Core.Outbox.Repo.Pg,
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

  ## Opts

  - `enabled:` — обязательна; `false` — дерево не стартует
  - `cluster_query:` — обязательна, без дефолта: запрос кластеризации; `nil`, `:ignore` и `""` —
    кластеризации нет
  - `allow_cluster:` — разрешить старт включённой очереди в кластере, по умолчанию `false`
  - `repo:` — обязательна; модуль `Core.Outbox.Repo` для поллеров и cleaner
  - `pollers:` — обязательна; список поллеров, элемент — keyword:
    - `name:` — обязательна; атом, имя процесса поллера
    - `label:` — обязательна; непустая строка, метка компонента в `watch_list/1`
    - `topics:` — `Core.Outbox.topics_filter()`, по умолчанию `:all`
    - ровно один из `writer: {модуль Mq.Writer, опции с name: атомом}` — writer-процесс, который
      дерево поднимает перед поллером и через `name:` которого поллер пишет, — и
      `via: {модуль Mq.Writer, handle}` — процесс, которым владеет приложение (клиент Kafka): дерево
      его не поднимает и не наблюдает
  - `connection:` — `{модуль, опции с name: атомом}`, первый ребёнок дерева: соединение, других
    пользователей у которого нет
  - `context_factory:` — `(-> Context.t())`, одна на поллеры и cleaner, по умолчанию `&Context.new/0`
  - `poll_interval_ms:`, `idle_min_ms:` — обязательны; backoff поллера (`Core.Outbox.Poller`)
  - `batch_size:`, `lock_duration_seconds:`, `max_attempts:` — обязательны; пачка, аренда и попытки
    поллера
  - `published_ttl_seconds:`, `cleaner_interval_ms:` — обязательны; TTL опубликованных записей и
    интервал cleaner

  Числа — положительные целые; в Prim (`Core.Outbox.BatchSize`, `LockDuration`, `Attempts`,
  `PublishedTTL`) их оборачивает дерево. Имена процессов дерева и метки поллеров MUST различаться.
  Доставку поллера дерево собирает само — `Core.Outbox.Delivery.Mq` над writer'ом элемента. Config
  и env библиотека не читает: опции собирает одна функция приложения, её же принимает
  `watch_list/1`.

  ## Старт

  `start_link/1` проверяет опции при любом `enabled:`: неизвестная, отсутствующая или недопустимая
  опция, оба или ни одного из `writer:` / `via:`, повтор имени или метки, `enabled: true` при
  `pollers: []` — `ArgumentError`. Затем две проверки старта:

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

  alias Core.Context
  alias Core.Helper.StartOpts
  alias Core.Outbox
  alias Core.Outbox.Cleaner
  alias Core.Outbox.Delivery
  alias Core.Outbox.Poller
  alias Core.Outbox.Supervisor.Mark

  require Logger

  @label "Outbox.Supervisor"
  @keys ~w(
    enabled cluster_query allow_cluster repo pollers connection context_factory poll_interval_ms idle_min_ms
    batch_size lock_duration_seconds max_attempts published_ttl_seconds cleaner_interval_ms
  )a
  @poller_keys ~w(name label topics writer via)a

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

  @typedoc "Проверенные опции дерева."
  @type options :: %{
          enabled: boolean(),
          cluster_query: cluster_query(),
          allow_cluster: boolean(),
          repo: module(),
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

  @doc "Запустить дерево очереди; `:ignore` — дерево отключено."
  @spec start_link(keyword()) :: Supervisor.on_start()

  def start_link(opts) when is_list(opts) do
    options = options!(opts)
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
          "#{@label}: очередь включена вместе с кластеризацией cluster_query=#{inspect(query)}: " <>
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
    "#{@label}: фильтры топиков поллеров пересекаются, порядок доставки не гарантирован: " <>
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
  @spec init(options()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}

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
      repo: options.repo,
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
     repo: options.repo,
     published_ttl: options.published_ttl,
     interval_ms: options.cleaner_interval_ms,
     context_factory: options.context_factory}
  end

  # ===== watch_list =====

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
    case options!(opts) do
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

  # ===== общее =====

  defp options!(opts) do
    StartOpts.keys!(@label, opts, @keys)
    enabled = StartOpts.boolean!(@label, opts, :enabled)
    pollers = Enum.map(StartOpts.list!(@label, opts, :pollers), &poller!/1)
    connection = connection!(Keyword.get(opts, :connection))
    ensure_pollers!(enabled, pollers)

    StartOpts.unique!(
      @label,
      :pollers,
      "имена процессов без повторов: имя — id ребёнка",
      process_names(connection, pollers)
    )

    StartOpts.unique!(
      @label,
      :pollers,
      "label: без повторов: по метке строится компонент",
      Enum.map(pollers, & &1.label)
    )

    %{
      enabled: enabled,
      cluster_query: cluster_query!(opts),
      allow_cluster: StartOpts.boolean!(@label, opts, :allow_cluster, false),
      repo: StartOpts.module!(@label, opts, :repo),
      pollers: pollers,
      connection: connection,
      context_factory: StartOpts.fun!(@label, opts, :context_factory, 0, &Context.new/0),
      poll_interval_ms: StartOpts.pos_integer!(@label, opts, :poll_interval_ms),
      idle_min_ms: StartOpts.pos_integer!(@label, opts, :idle_min_ms),
      batch_size: prim!(opts, :batch_size, Outbox.BatchSize),
      lock_duration: prim!(opts, :lock_duration_seconds, Outbox.LockDuration),
      max_attempts: prim!(opts, :max_attempts, Outbox.Attempts),
      published_ttl: prim!(opts, :published_ttl_seconds, Outbox.PublishedTTL),
      cleaner_interval_ms: StartOpts.pos_integer!(@label, opts, :cleaner_interval_ms)
    }
  end

  defp cluster_query!(opts) do
    case Keyword.fetch(opts, :cluster_query) do
      {:ok, query} when query in [nil, :ignore] or is_binary(query) -> query
      {:ok, other} -> StartOpts.raise_invalid!(@label, :cluster_query, "строку, nil или :ignore", other)
      :error -> raise ArgumentError, "#{@label}: нет обязательной опции :cluster_query"
    end
  end

  defp prim!(opts, key, mod) do
    value = StartOpts.pos_integer!(@label, opts, key)

    case mod.new(value) do
      {:ok, prim} -> prim
      {:error, _reason} -> StartOpts.raise_invalid!(@label, key, "значение #{inspect(mod)}", value)
    end
  end

  defp ensure_pollers!(true, []) do
    raise ArgumentError, "#{@label}: enabled: true при pollers: [] — очереди нечем доставлять записи"
  end

  defp ensure_pollers!(_enabled, _pollers), do: :ok

  defp poller!(poller) do
    unless Keyword.keyword?(poller),
      do: StartOpts.raise_invalid!(@label, :pollers, "список keyword [name: …, label: …, writer: … | via: …]", poller)

    StartOpts.keys!(@label, poller, @poller_keys)
    {writer, via} = transport!(poller)

    %{
      name: StartOpts.atom!(@label, poller, :name),
      label: StartOpts.binary!(@label, poller, :label),
      topics: StartOpts.topics_filter!(@label, poller, :topics, :all),
      writer: writer,
      via: via
    }
  end

  defp transport!(poller) do
    case {Keyword.fetch(poller, :writer), Keyword.fetch(poller, :via)} do
      {{:ok, spec}, :error} ->
        %{module: module, name: name} = writer = StartOpts.process!(@label, :writer, spec)
        {writer, {module, name}}

      {:error, {:ok, via}} ->
        {nil, via!(via)}

      _both_or_none ->
        StartOpts.raise_invalid!(@label, :pollers, "ровно один из writer: и via: у поллера", poller)
    end
  end

  defp via!({module, handle} = via) when is_atom(module) and not is_nil(module) and not is_nil(handle), do: via

  defp via!(other), do: StartOpts.raise_invalid!(@label, :via, "{модуль Mq.Writer, handle процесса}", other)

  defp connection!(nil), do: nil

  defp connection!(spec), do: StartOpts.process!(@label, :connection, spec)

  defp process_names(connection, pollers) do
    processes = [connection | Enum.map(pollers, & &1.writer)]
    [Cleaner | for(%{name: name} <- processes, do: name)] ++ Enum.map(pollers, & &1.name)
  end
end
