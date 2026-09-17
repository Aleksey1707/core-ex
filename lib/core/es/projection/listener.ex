defmodule Core.Es.Projection.Listener do
  @moduledoc """
  Слушатель канала сигнала чекпоинта — процесс дерева `Core.Es.Projection.Supervisor`, по одному на
  каждый различный `repo:` проекций. Уведомление пачки любой ноды он переводит в сигнал чекпоинта
  через `Core.Es.Projection.Registry`: ожидающие `await/3` модуля проекции на этой ноде
  перечитывают чекпоинт без кластера Erlang (`docs/adr/0013-checkpoint-signal-listen-notify.md`).

  ## Протокол канала

  - канал — `core_es_checkpoint`, один на все проекции;
  - payload — `name:` проекции как есть, больше ничего: ожидающий перечитывает строку чекпоинта;
  - шлёт пачка `Core.Es.Projection.Batch` в своей транзакции после сдвига чекпоинта или старта с
    начала истории: отказ пачки откатывает транзакцию, и уведомление не доставляется;
  - `Core.Es.Store.append/5` в канал не шлёт.

  Имя канала и формат payload — протокол между нодами разных версий: их смена — ломающее изменение
  с записью в CHANGELOG и ADR. Уведомление с именем проекции, которой на ноде нет, никого не будит.

  Пачка не шлёт уведомление, только если отметка дерева на ноде есть и в ней
  `notifications: false`: `NOTIFY` берёт на commit общую на кластер блокировку и без слушателей.
  Отметки нет — дерево на ноде не стартовало, `run_once/2` вручную — пачка шлёт.

  ## Процесс

  В `init/1` запросов нет. В `handle_continue/2` слушатель запускает связанный
  `Postgrex.Notifications` и подписывается на канал. Опции соединения — `repo.config()`, поверх —
  keyword из `notifications:` дерева (например прямой хост в обход pgbouncer в transaction mode);
  `sync_connect: false` и `auto_reconnect: true` не переопределяются: база, недоступная на старте,
  не роняет дерево. После разрыва `Postgrex.Notifications` переподключается сам и повторяет
  `LISTEN`; уведомления за время разрыва теряются, и ожидание доходит шагами. Разрывы логирует
  Postgrex, своих логов и telemetry у слушателя нет.
  """

  use GenServer

  alias Core.Es.Projection

  @channel "core_es_checkpoint"

  @typedoc "Repo проекций и опции соединения поверх его конфигурации."
  @type state :: %{repo: module(), connection: keyword()}

  # ===== процесс =====

  @doc "Спецификация для Supervisor: `:id` — `{Core.Es.Projection.Listener, repo}`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :repo)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Запустить слушателя на соединении `repo:` с опциями `connection:` поверх `repo.config()`."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  @spec init(keyword()) :: {:ok, state(), {:continue, :listen}}

  @impl true
  def init(opts) do
    state = %{repo: Keyword.fetch!(opts, :repo), connection: Keyword.fetch!(opts, :connection)}
    {:ok, state, {:continue, :listen}}
  end

  @doc false
  @spec handle_continue(:listen, state()) :: {:noreply, state()}

  @impl true
  def handle_continue(:listen, %{repo: repo, connection: connection} = state) do
    {:ok, server} = Postgrex.Notifications.start_link(connection_opts(repo, connection))

    # Без соединения подписка отвечает `{:eventually, _}`: `LISTEN` уйдёт после подключения. Вызов
    # ждёт текущую попытку подключения, её ограничивает `connect_timeout` Postgrex; свой таймаут
    # короче ронял бы слушателя на недоступном хосте раньше, чем Postgrex уйдёт в переподключение.
    {_listening, _ref} = Postgrex.Notifications.listen(server, @channel, timeout: :infinity)

    {:noreply, state}
  end

  @doc false
  @spec handle_info({:notification, pid(), reference(), String.t(), String.t()}, state()) ::
          {:noreply, state()}

  @impl true
  def handle_info({:notification, _notifications, _ref, @channel, name}, state) do
    :ok = Projection.Registry.signal_checkpoint(name)
    {:noreply, state}
  end

  # ---

  defp connection_opts(repo, connection) do
    repo.config()
    |> Keyword.merge(connection)
    |> Keyword.merge(sync_connect: false, auto_reconnect: true)
  end

  # ===== отправка =====

  @doc false
  @spec notify(Projection.t()) :: :ok

  def notify(%{dao: dao, name: name}) do
    case Projection.Supervisor.Mark.find() do
      %{notifications: false} -> :ok
      _mark -> notify(dao, name)
    end
  end

  # ---

  defp notify(dao, name) do
    %{num_rows: 1} = Ecto.Adapters.SQL.query!(dao, "SELECT pg_notify($1, $2)", [@channel, name])
    :ok
  end
end
