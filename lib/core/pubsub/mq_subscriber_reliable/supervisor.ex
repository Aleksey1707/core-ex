defmodule Core.PubSub.MqSubscriberReliable.Supervisor do
  @moduledoc """
  Дерево подписчиков брокера с DLQ: порядок детей из свода держится построением.

      {Core.PubSub.MqSubscriberReliable.Supervisor,
       enabled: true,
       name: MyApp.Notify.Supervisor,
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
  `Core.PubSub.MqSubscriberReliable`. Падение DLQ-writer'а перезапускает всех, падение читателя —
  его подписчика и топики после него. Подписчик стартует с `subscribe: true`: подписан сразу после
  `init/1`, процесс-bootstrap с `subscribe/3` не нужен.

  Handle писателя и читателя — их `name:`: дерево передаёт подписчику `reader_module:` и `reader:`
  читателя своего топика, `dlq_writer:` и `dlq_handle:` DLQ-writer'а.

  ## Opts

  - `enabled:` — обязательна; `false` — дерево не стартует
  - `topics:` — обязательна; список `[reader: {модуль, опции}, subscriber: опции]` по топику
  - `dlq_writer:` — `{модуль Mq.Writer, опции}`; без него подписчик после `max_attempts` продолжает
    повторы (`Core.PubSub.MqSubscriberReliable`, «DLQ»)
  - `name:` — имя супервизора, оно же `id` в `child_spec/1`; по умолчанию без имени, `id` — модуль

  Опции писателя и читателя MUST содержать `name:` — атом. Опции подписчика MUST содержать `name:`
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

  alias Core.Helper.StartOpts
  alias Core.PubSub.MqSubscriberReliable

  require Logger

  @label "PubSub.MqSubscriberReliable.Supervisor"
  @keys ~w(enabled topics dlq_writer name)a
  @topic_keys ~w(reader subscriber)a
  @owned_keys ~w(reader_module reader dlq_writer dlq_handle subscribe)a
  @process_expected "{модуль, опции с name: атомом}"

  @typedoc "Процесс брокера: модуль, его опции и имя — оно же handle."
  @type process :: %{module: module(), opts: keyword(), name: atom()}

  @typedoc "Топик: читатель и подписчик — его опции и имя."
  @type topic :: %{reader: process(), subscriber: %{opts: keyword(), name: atom()}}

  @typedoc "Проверенные опции дерева."
  @type options :: %{
          enabled: boolean(),
          topics: [topic()],
          dlq_writer: process() | nil,
          name: GenServer.name() | nil
        }

  @typedoc "Элемент `watch:` плагина `Core.Workers.PromEx`."
  @type watch_item :: %{component: String.t(), name: atom()}

  # ===== старт =====

  @doc "Спецификация ребёнка супервизора: `id` — `name:` дерева, без него — модуль."
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{
      id: StartOpts.name!(@label, opts, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Запустить дерево подписчиков; `:ignore` — дерево отключено или топиков нет."
  @spec start_link(keyword()) :: Supervisor.on_start()

  def start_link(opts) when is_list(opts), do: start(options!(opts))

  # ---

  defp start(%{enabled: false, topics: topics}) do
    Logger.info("супервизор подписчиков: отключён: subscribers=#{names(topics)}")
    :ignore
  end

  defp start(%{topics: []}) do
    Logger.info("супервизор подписчиков: пропущен: нет топиков")
    :ignore
  end

  defp start(%{topics: topics, name: name} = options) do
    start_opts = if name, do: [name: name], else: []

    with {:ok, _pid} = started <- Supervisor.start_link(__MODULE__, options, start_opts) do
      Logger.info("супервизор подписчиков: запущен: subscribers=#{names(topics)}")
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
  `component: "mq_dlq_writer:<имя>"`, `"mq_reader:<имя>"`, `"mq_subscriber:<имя>"`.

  `opts` — опции дерева, проверяются как в `start_link/1`. Когда дерево не стартует
  (`enabled: false`, `topics: []`), элементов нет: процессов на ноде нет, и `up=0` был бы ложной
  тревогой.
  """
  @spec watch_list(keyword()) :: [watch_item()]

  def watch_list(opts) when is_list(opts) do
    case options!(opts) do
      %{enabled: false} -> []
      %{topics: []} -> []
      %{topics: topics, dlq_writer: dlq_writer} -> dlq_items(dlq_writer) ++ Enum.flat_map(topics, &topic_items/1)
    end
  end

  # ---

  defp dlq_items(nil), do: []

  defp dlq_items(%{name: name}), do: [watch_item("mq_dlq_writer", name)]

  defp topic_items(%{reader: reader, subscriber: subscriber}),
    do: [watch_item("mq_reader", reader.name), watch_item("mq_subscriber", subscriber.name)]

  defp watch_item(kind, name), do: %{component: "#{kind}:#{inspect(name)}", name: name}

  # ===== общее =====

  defp options!(opts) do
    StartOpts.keys!(@label, opts, @keys)

    %{
      enabled: StartOpts.boolean!(@label, opts, :enabled),
      topics: Enum.map(StartOpts.list!(@label, opts, :topics), &topic!/1),
      dlq_writer: dlq_writer!(Keyword.get(opts, :dlq_writer)),
      name: StartOpts.name!(@label, opts, :name)
    }
  end

  defp dlq_writer!(nil), do: nil

  defp dlq_writer!(spec), do: process!(:dlq_writer, spec)

  defp topic!(topic) do
    unless Keyword.keyword?(topic),
      do: StartOpts.raise_invalid!(@label, :topics, "список keyword [reader: …, subscriber: …]", topic)

    StartOpts.keys!(@label, topic, @topic_keys)

    %{
      reader: process!(:reader, StartOpts.term!(@label, topic, :reader)),
      subscriber: subscriber!(StartOpts.list!(@label, topic, :subscriber))
    }
  end

  defp process!(key, {module, opts} = spec) when is_atom(module) and not is_nil(module) and is_list(opts) do
    case Keyword.get(opts, :name) do
      name when is_atom(name) and not is_nil(name) -> %{module: module, opts: opts, name: name}
      _other -> StartOpts.raise_invalid!(@label, key, @process_expected, spec)
    end
  end

  defp process!(key, spec), do: StartOpts.raise_invalid!(@label, key, @process_expected, spec)

  defp subscriber!(opts) do
    case Enum.find(@owned_keys, &Keyword.has_key?(opts, &1)) do
      nil ->
        StartOpts.binary!(@label, opts, :topic)
        %{opts: opts, name: StartOpts.atom!(@label, opts, :name)}

      key ->
        StartOpts.raise_invalid!(@label, :subscriber, "опции подписчика без #{inspect(key)}: её задаёт дерево", opts)
    end
  end
end
