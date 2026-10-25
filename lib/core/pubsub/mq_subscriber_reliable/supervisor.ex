defmodule Core.PubSub.MqSubscriberReliable.Supervisor do
  @tree_opts_schema [
    enabled: [type: :boolean, required: true, doc: "`false` — дерево не стартует."],
    component: [
      type: {:custom, Core.PubSub.MqSubscriberReliable.Supervisor, :component, []},
      type_doc: "`t:String.t/0`",
      required: true,
      doc:
        "Непустая строка без `:`; из неё и топика строятся метки `component` метрик (`watch_list/1`, " <>
          "`stream_readers/1`), `:` — их разделитель."
    ],
    topics: [
      type:
        {:list,
         {:keyword_list,
          [
            reader: [
              type: {:tuple, [:atom, :keyword_list]},
              required: true,
              doc: "Читатель топика `{модуль Core.Mq.ReaderReliable, опции}`."
            ],
            subscriber: [
              type: {:custom, Core.PubSub.MqSubscriberReliable.Supervisor, :subscriber, []},
              required: true,
              doc: "Опции `Core.PubSub.MqSubscriberReliable` подписчика топика."
            ]
          ]}},
      type_doc: "список `[reader: {module(), keyword()}, subscriber: keyword()]`",
      required: true,
      doc: "По элементу на топик: читатель и опции его подписчика; топики подписчиков без повторов."
    ],
    dlq_writer: [
      type: {:tuple, [:atom, :keyword_list]},
      type_doc: "`{module(), keyword()}`",
      doc:
        "DLQ-writer `{модуль Core.Mq.Writer, опции}`; без него подписчик после `max_attempts` продолжает " <>
          "повторы (`Core.PubSub.MqSubscriberReliable`, «DLQ»)."
    ],
    name: Core.Helper.StartOpts.name_option("Имя супервизора, оно же `id` в `child_spec/1`; без него `id` — модуль.")
  ]

  @moduledoc """
  Дерево подписчиков брокера с DLQ: порядок детей из свода держится построением.

      {Core.PubSub.MqSubscriberReliable.Supervisor,
       enabled: true,
       component: "notify",
       name: MyApp.Notify.Subscribers,
       dlq_writer:
         {Core.Mq.Stream.Writer,
          connection: MyApp.Mq.Connection, reference_prefix: "notify-dlq", name: MyApp.Notify.Dlq},
       topics: [
         [
           reader:
             {Core.Mq.Stream.Reader,
              connection: MyApp.Mq.Connection,
              topic: "accounts",
              subscriber_name: "notify",
              name: MyApp.Notify.AccountsReader},
           subscriber: [
             name: MyApp.Notify.AccountsSubscriber,
             topic: "accounts",
             from_message: &MyApp.Notify.from_message/1,
             on_message: &MyApp.Notify.on_message/3
           ]
         ]
       ]}

  Внутри — `rest_for_one`: DLQ-writer (если задан) → на каждый топик читатель и его
  `Core.PubSub.MqSubscriberReliable`. Падение DLQ-writer'а перезапускает всех; падение читателя —
  его подписчика и топики после него; падение подписчика — его самого и топики после него, читатель
  его топика остаётся. Бюджет рестартов у топиков общий. Подписчик стартует с `subscribe: true`:
  подписан сразу после `init/1`, процесс-bootstrap с `subscribe/3` не нужен.

  Handle писателя и читателя — их `name:`: дерево передаёт подписчику `reader_module:` и `reader:`
  читателя своего топика, `dlq_writer:` и `dlq_handle:` DLQ-writer'а.

  ## Опции

  Опции дерева — раздел «Опции» у `start_link/1`; те же опции принимают `watch_list/1`,
  `stream_readers/1` и `kafka_readers/1`. Неизвестная опция, отсутствие обязательной и значение не
  той формы — `ArgumentError`.

  Опции писателя и читателя MUST содержать `name:` — атом; имена всех процессов дерева MUST
  различаться: имя — `id` ребёнка. Опции подписчика MUST содержать `name:`
  (атом) и `topic:` (непустая строка) и MUST NOT содержать `reader_module:`, `reader:`,
  `dlq_writer:`, `dlq_handle:`, `subscribe:` — их задаёт дерево; остальные опции подписчика
  проверяет он сам при старте. Config и env библиотека не читает.

  ## Старт

  `start_link/1` проверяет опции при любом `enabled:`, недопустимая — `ArgumentError`. Затем:

  - `enabled: false` — `:ignore`, `info` «отключён»;
  - `topics: []` — `:ignore`, `info` «пропущен: нет топиков»;
  - иначе дерево стартует, `info` «запущен».
  """

  use Supervisor
  use Core.Options

  alias Core.Helper.StartOpts
  alias Core.PubSub.MqSubscriberReliable
  alias Core.Result

  require Logger

  @owned_keys ~w(reader_module reader dlq_writer dlq_handle subscribe)a
  @stream_reader Core.Mq.Stream.Reader
  @kafka_reader Core.Mq.Kafka.Reader

  @typedoc "Процесс брокера: модуль, его опции и имя — оно же handle."
  @type process :: StartOpts.process()

  @typedoc "Топик: читатель и подписчик — его опции, имя и топик."
  @type topic :: %{reader: process(), subscriber: %{opts: keyword(), name: atom(), topic: String.t()}}

  @typedoc "Проверенные опции дерева."
  @type options :: %{
          enabled: boolean(),
          component: String.t(),
          topics: [topic()],
          dlq_writer: process() | nil,
          name: GenServer.name() | nil
        }

  @typedoc """
  Элемент `watch:` плагина `Core.Workers.PromEx` и `stream_readers:` / `kafka_readers:` плагина
  `Core.Mq.PromEx`.
  """
  @type watch_item :: %{component: String.t(), name: atom()}

  # ===== старт =====

  @doc "Спецификация ребёнка супервизора: `id` — `name:` дерева, без него — модуль."
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Запустить дерево подписчиков; `:ignore` — дерево отключено или топиков нет."
  @opts_schema @tree_opts_schema
  @spec start_link(keyword()) :: Supervisor.on_start()

  def start_link(opts) when is_list(opts), do: start(options!(opts, fun_label(:start_link)))

  # ---

  defp start(%{enabled: false, component: component, topics: topics}) do
    Logger.info("супервизор подписчиков: отключён: subscribers=#{names(topics)} component=#{component}")
    :ignore
  end

  defp start(%{topics: [], component: component}) do
    Logger.info("супервизор подписчиков: пропущен: нет топиков component=#{component}")
    :ignore
  end

  defp start(%{topics: topics, name: name, component: component} = options) do
    start_opts = if name, do: [name: name], else: []

    with {:ok, _pid} = started <- Supervisor.start_link(__MODULE__, options, start_opts) do
      Logger.info("супервизор подписчиков: запущен: subscribers=#{names(topics)} component=#{component}")
      started
    end
  end

  defp names(topics), do: Enum.map_join(topics, ",", &inspect(&1.subscriber.name))

  # ===== дети =====

  @doc false
  @spec init(options()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}

  @impl true
  def init(%{topics: topics, dlq_writer: dlq_writer}) do
    dlq_opts = dlq_opts(dlq_writer)
    children = dlq_children(dlq_writer) ++ Enum.flat_map(topics, &topic_children(&1, dlq_opts))

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # ---

  defp dlq_opts(nil), do: []
  defp dlq_opts(%{module: module, name: name}), do: [dlq_writer: module, dlq_handle: name]

  defp dlq_children(nil), do: []
  defp dlq_children(dlq_writer), do: [child(dlq_writer)]

  defp topic_children(%{reader: reader, subscriber: subscriber}, dlq_opts) do
    tree_opts = [reader_module: reader.module, reader: reader.name, subscribe: true] ++ dlq_opts

    [child(reader), {MqSubscriberReliable, subscriber.opts ++ tree_opts}]
  end

  defp child(%{module: module, opts: opts, name: name}), do: Supervisor.child_spec({module, opts}, id: name)

  # ===== watch_list =====

  @doc """
  Элементы `watch:` плагина `Core.Workers.PromEx` — все процессы дерева в порядке старта:
  `component: "mq_dlq_writer:<component>"`, `"mq_reader:<component>:<топик>"`,
  `"mq_subscriber:<component>:<топик>"`.

  Метка строится из `component:` дерева и `topic:` подписчика, а не из имени процесса: перенос
  модуля компонента не меняет ряды метрик. `opts` — опции дерева, как у `start_link/1`.
  Когда дерево не стартует (`enabled: false`, `topics: []`), элементов нет: процессов на ноде нет,
  и `up=0` был бы ложной тревогой.
  """
  @opts_schema @tree_opts_schema
  @spec watch_list(keyword()) :: [watch_item()]

  def watch_list(opts) when is_list(opts) do
    case options!(opts, fun_label(:watch_list)) do
      %{enabled: false} ->
        []

      %{topics: []} ->
        []

      %{component: component, topics: topics, dlq_writer: dlq_writer} ->
        dlq_items(dlq_writer, component) ++ Enum.flat_map(topics, &topic_items(&1, component))
    end
  end

  # ---

  defp dlq_items(nil, _component), do: []
  defp dlq_items(%{name: name}, component), do: [%{component: "mq_dlq_writer:#{component}", name: name}]

  defp topic_items(%{subscriber: subscriber} = topic, component) do
    [
      reader_item(topic, component),
      %{component: "mq_subscriber:#{label(component, subscriber)}", name: subscriber.name}
    ]
  end

  # ===== readers =====

  @doc """
  Элементы `stream_readers:` плагина `Core.Mq.PromEx` — stream-читатели дерева с той же меткой, что у
  `mq_reader` в `watch_list/1`: `component: "mq_reader:<component>:<топик>"`.

  Читатель другого модуля в список не попадает: у `Core.Mq.Kafka.Reader` своя группа метрик опроса
  (`kafka_readers/1`), у прочих её нет. Когда дерево не стартует (`enabled: false`, `topics: []`), элементов нет.
  """
  @opts_schema @tree_opts_schema
  @spec stream_readers(keyword()) :: [watch_item()]

  def stream_readers(opts) when is_list(opts), do: reader_items(opts, @stream_reader, fun_label(:stream_readers))

  @doc """
  Элементы `kafka_readers:` плагина `Core.Mq.PromEx` — читатели Kafka дерева с той же меткой, что
  у `mq_reader` в `watch_list/1`: `component: "mq_reader:<component>:<топик>"`.

  Читатель другого модуля в список не попадает. Когда дерево не стартует (`enabled: false`,
  `topics: []`), элементов нет.
  """
  @opts_schema @tree_opts_schema
  @spec kafka_readers(keyword()) :: [watch_item()]

  def kafka_readers(opts) when is_list(opts), do: reader_items(opts, @kafka_reader, fun_label(:kafka_readers))

  # ---

  defp reader_items(opts, module, label) do
    case options!(opts, label) do
      %{enabled: false} ->
        []

      %{topics: []} ->
        []

      %{component: component, topics: topics} ->
        for %{reader: %{module: ^module}} = topic <- topics,
            do: reader_item(topic, component)
    end
  end

  # ===== проверка опций =====

  @doc false
  @spec component(term()) :: Result.t(String.t(), String.t())

  def component(value) do
    case Core.Options.Type.binary(value) do
      {:ok, component} ->
        if String.contains?(component, ":"),
          do: {:error, "ожидается строка без `:` — разделителя метки, получено #{inspect(component)}"},
          else: {:ok, component}

      {:error, _message} = error ->
        error
    end
  end

  @doc false
  @spec subscriber(term()) :: Result.t(keyword(), String.t())

  def subscriber(subscriber) do
    cond do
      not Keyword.keyword?(subscriber) ->
        {:error, "ожидаются опции подписчика keyword-списком, получено #{inspect(subscriber)}"}

      key = Enum.find(@owned_keys, &Keyword.has_key?(subscriber, &1)) ->
        {:error, "ожидаются опции подписчика без #{inspect(key)}: её задаёт дерево, получено #{inspect(subscriber)}"}

      true ->
        subscriber_ids(subscriber)
    end
  end

  # ---

  defp subscriber_ids(subscriber) do
    case {Keyword.get(subscriber, :name), Core.Options.Type.binary(Keyword.get(subscriber, :topic))} do
      {name, {:ok, _topic}} when is_atom(name) and not is_nil(name) -> {:ok, subscriber}
      {name, {:ok, _topic}} -> {:error, "ожидается name: подписчика атомом, получено #{inspect(name)}"}
      {_name, {:error, message}} -> {:error, "topic: подписчика — #{message}"}
    end
  end

  # ===== общее =====

  defp reader_item(%{reader: reader, subscriber: subscriber}, component),
    do: %{component: "mq_reader:#{label(component, subscriber)}", name: reader.name}

  defp label(component, %{topic: topic}), do: "#{component}:#{topic}"

  defp fun_label(fun), do: "#{inspect(__MODULE__)}.#{fun}/1"

  defp options!(opts, label) do
    options = %{
      enabled: Keyword.fetch!(opts, :enabled),
      component: Keyword.fetch!(opts, :component),
      topics: topics!(Keyword.fetch!(opts, :topics), label),
      dlq_writer: dlq_writer!(Keyword.get(opts, :dlq_writer), label),
      name: Keyword.get(opts, :name)
    }

    Core.Options.unique!(label, :topics, "имена процессов без повторов: имя — id ребёнка", process_names(options))
    options
  end

  defp process_names(%{dlq_writer: dlq_writer, topics: topics}) do
    dlq = if dlq_writer, do: [dlq_writer.name], else: []
    dlq ++ Enum.flat_map(topics, &[&1.reader.name, &1.subscriber.name])
  end

  defp dlq_writer!(nil, _label), do: nil
  defp dlq_writer!(spec, label), do: StartOpts.process!(label, :dlq_writer, spec)

  defp topics!(topics, label) do
    parsed = Enum.map(topics, &topic!(&1, label))

    Core.Options.unique!(
      label,
      :topics,
      "топики без повторов: по топику строится метка",
      Enum.map(parsed, & &1.subscriber.topic)
    )

    parsed
  end

  defp topic!(topic, label) do
    subscriber = Keyword.fetch!(topic, :subscriber)

    %{
      reader: StartOpts.process!(label, :reader, Keyword.fetch!(topic, :reader)),
      subscriber: %{
        opts: subscriber,
        name: Keyword.fetch!(subscriber, :name),
        topic: Keyword.fetch!(subscriber, :topic)
      }
    }
  end
end
