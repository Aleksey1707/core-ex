defmodule Core.Outbox.Test.Reactor do
  @init_opts_schema [
    subscribers: [
      type: {:list, :keyword_list},
      required: true,
      doc: "Подписчики в форме `Core.Outbox.Test`; недопустимый подписчик — `ArgumentError` при старте."
    ],
    owner: [
      type: :pid,
      required: true,
      doc:
        "Владелец; `child_spec/1` по умолчанию берёт процесс, который строит спецификацию ребёнка: тест, " <>
          "если он зовёт `start_supervised` сам; из `setup_all` или чужого процесса `owner:` MUST " <>
          "передаваться явно."
    ]
  ]

  @moduledoc """
  Реактор дублёра доставки: `Core.Outbox.Test.drain/2` в фоне, раз в 10 мс.

  Нужен приёмочному тесту через HTTP: запрос ждёт проекцию события реакции, и гнать цепочку
  реакций, пока тест заблокирован, некому. Перед проверками тест зовёт
  `Core.Outbox.Test.settle/2`, мёртвые письма читает `Core.Outbox.Test.dead_letters/1` с реактором.

      reactor = start_supervised!({Core.Outbox.Test.Reactor, subscribers: MyApp.Notify.subscribers()})

  Реактор ставит себе `$callers = [владелец]`: sandbox Ecto и прочие владения по `$callers` видят
  его без `allow`, и тест остаётся `async: true`. Подписки на commit нет — только опрос.

  Реактор не перезапускается (`restart: :temporary`): журналы, курсоры и мёртвые письма живут в
  нём. Исключение прохода останавливает опрос, и `settle/2` валит тест с его текстом. С выходом
  владельца реактор останавливается сам: sandbox теста ему больше не доступен.

  ## Опции старта

  Неизвестная опция, отсутствие обязательной и значение не той формы — `ArgumentError` в `init/1`.

  #{Core.Options.docs(@init_opts_schema)}
  """

  use GenServer
  use Core.Options

  alias Core.Outbox

  require Logger

  @label "Outbox.Test.Reactor"
  @interval_ms 10
  @shutdown_ms 30_000

  @doc """
  Спецификация ребёнка; `owner:` по умолчанию — вызывающий процесс. Остановка ждёт конца прохода
  до #{@shutdown_ms} мс.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [Keyword.put_new(opts, :owner, self())]},
      restart: :temporary,
      shutdown: @shutdown_ms
    }
  end

  @doc "Запустить реактор."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @opts_schema @init_opts_schema
  @doc false
  @spec init(keyword()) :: {:ok, %{subscribers: [keyword()], owner: pid(), crash: String.t() | nil}}

  @impl true
  def init(opts) do
    # Остановка ждёт конца прохода: убитый посреди запроса реактор рвёт соединение sandbox теста.
    Process.flag(:trap_exit, true)
    subscribers = Keyword.fetch!(opts, :subscribers)
    :ok = Outbox.Test.check_subscribers!(subscribers)
    owner = Keyword.fetch!(opts, :owner)
    Process.put(:"$callers", [owner])
    _ref = Process.monitor(owner)
    {:ok, schedule(%{subscribers: subscribers, owner: owner, crash: nil}, 0)}
  end

  @doc false
  @impl true
  def handle_info(:tick, state) do
    case safe_drain(state.subscribers) do
      :ok ->
        {:noreply, schedule(state, @interval_ms)}

      {:crashed, banner, text} ->
        crashed(state, banner, text)
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state), do: {:stop, :normal, state}
  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @impl true
  def handle_call(:report, _from, %{crash: nil} = state),
    do: {:reply, {:ok, Outbox.Test.report(state.subscribers)}, state}

  def handle_call(:report, _from, state), do: {:reply, {:crashed, state.crash}, state}
  def handle_call(:dead_letters, _from, state), do: {:reply, Outbox.Test.dead_letters(self()), state}

  # ---

  defp safe_drain(subscribers) do
    Outbox.Test.drain(subscribers)
  rescue
    exception -> crash(:error, exception, __STACKTRACE__)
  catch
    :exit, reason -> crash(:exit, reason, __STACKTRACE__)
  end

  defp crash(kind, reason, stacktrace),
    do: {:crashed, Exception.format_banner(kind, reason, stacktrace), Exception.format(kind, reason, stacktrace)}

  # Проход, упавший после выхода владельца, — закрытый sandbox, а не сбой доставки.
  defp crashed(state, banner, text) do
    if Process.alive?(state.owner) do
      Logger.error("#{@label}: проход доставки упал, опрос остановлен: error=#{inspect(banner)}")
      {:noreply, %{state | crash: text}}
    else
      {:stop, :normal, state}
    end
  end

  defp schedule(state, ms) do
    _ref = Process.send_after(self(), :tick, ms)
    state
  end
end
