defmodule Core.Es.Aggregate.Process.Server do
  @moduledoc """
  Процесс агрегата на id — ребёнок `DynamicSupervisor` дерева `Core.Es.Aggregate.Process`
  (`enabled: true`) под ключом id в его `Registry`: держит состояние агрегата после последнего
  commit и исполняет команды по одной. Поведение и исходы — `@moduledoc`
  `Core.Es.Aggregate.Process`, «Процесс на id».

  `execute/4` — сторона вызывающего: вызов по имени в `Registry`, при `:noproc` — старт процесса
  и один повтор. Сам процесс в `init/1` запросов не делает, а команду исполняет
  `Core.Es.Aggregate.Process.Execution` в окружении вызывающего.

  Команда идёт целиком в одном `handle_call/3`: процесс ставит `trap_exit`, и остановка
  супервизором ждёт её конца в пределах `:shutdown` дочерней спецификации.

  Состояние хранится с отметкой последнего полного чтения (`get_decision`): старше
  `state_max_age:` — `stale?/3` — оно выбрасывается до команды.
  """

  use GenServer

  import Core.Bind

  alias Core.Es.Aggregate.Process.Execution
  alias Core.Otel
  alias Core.Repo
  alias Core.Telemetry

  require Logger

  # Запас на команду с `timeout:` по умолчанию (5 000 мс): дедлайн, истёкший до commit, откатывает
  # транзакцию, и дольше команда процесс не держит.
  @shutdown_ms 10_000

  @enforce_keys ~w(cfg id aggregate_id idle_timeout state_max_age)a
  defstruct @enforce_keys ++ [:state, :read_at]

  @typedoc "Аргументы старта: объявление `use`, адрес агрегата, простой до ухода и предел возраста состояния."
  @type args :: %{
          cfg: Core.Es.Aggregate.Process.cfg(),
          id: struct(),
          aggregate_id: String.t(),
          idle_timeout: pos_integer(),
          state_max_age: pos_integer() | :infinity
        }

  @typedoc "Запрос команды: вызов, адрес и дедлайн, момент постановки в очередь и окружение."
  @type request :: %{
          call: Core.Es.Aggregate.Process.call(),
          target: Execution.target(),
          enqueued_at: integer(),
          otel_ctx: Otel.ctx(),
          metadata: keyword()
        }

  @typedoc "Ответ процесса: результат команды, число повторов и ожидание в очереди (native)."
  @type reply :: {Execution.result(), non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          cfg: Core.Es.Aggregate.Process.cfg(),
          id: struct(),
          aggregate_id: String.t(),
          idle_timeout: pos_integer(),
          state_max_age: pos_integer() | :infinity,
          state: struct() | nil,
          read_at: integer() | nil
        }

  # ===== вызов =====

  @doc """
  Исполнить команду `call` в процессе агрегата: результат, число повторов и ожидание в очереди.

  Процесса нет (`:noproc`) или он ушёл по простою, не приняв команду, — старт под
  `DynamicSupervisor` дерева и один повтор вызова. Истечение дедлайна и падение процесса — exit.
  """
  @spec execute(
          Core.Es.Aggregate.Process.cfg(),
          Core.Es.Aggregate.Process.options(),
          Core.Es.Aggregate.Process.call(),
          Execution.target()
        ) :: reply()

  def execute(cfg, options, call, %{deadline: deadline} = target) when is_integer(deadline) do
    message = {:execute, request(call, target)}

    case call_registered(cfg.registry, call.id, message, deadline) do
      :gone ->
        GenServer.call(
          ensure_started(cfg, options, call.id, target),
          message,
          remaining(deadline)
        )

      reply ->
        reply
    end
  end

  # ---

  defp request(call, target) do
    %{
      call: call,
      target: target,
      enqueued_at: System.monotonic_time(),
      otel_ctx: Otel.ctx(),
      metadata: Logger.metadata()
    }
  end

  # Процесс, которого нет или который ушёл по простою до ответа, команду не исполнял: её можно
  # отправить заново.
  defp call_registered(registry, id, message, deadline) do
    GenServer.call({:via, Registry, {registry, id}}, message, remaining(deadline))
  catch
    :exit, {reason, {GenServer, :call, _args}} when reason in ~w(noproc normal)a -> :gone
  end

  defp ensure_started(cfg, options, id, target) do
    args = %{
      cfg: cfg,
      id: id,
      aggregate_id: target.aggregate_id,
      idle_timeout: options.idle_timeout,
      state_max_age: options.state_max_age
    }

    case DynamicSupervisor.start_child(cfg.supervisor, {__MODULE__, args}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # ===== процесс =====

  @doc """
  Спецификация для `DynamicSupervisor`: `restart: :temporary` — упавший или ушедший процесс не
  рестартует, следующая команда стартует новый; `:shutdown` — запас на команду, которую процесс
  дописывает под `trap_exit`.
  """
  @spec child_spec(args()) :: Supervisor.child_spec()

  def child_spec(%{cfg: _cfg, id: _id} = args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      shutdown: @shutdown_ms
    }
  end

  @doc "Запустить процесс агрегата под ключом id в `Registry` дерева."
  @spec start_link(args()) :: GenServer.on_start()

  def start_link(%{cfg: cfg, id: id} = args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {cfg.registry, id}})

  @doc false
  @spec init(args()) :: {:ok, t(), pos_integer()}

  @impl true
  def init(args) do
    # Команда идёт целиком в одном `handle_call/3`: без trap_exit остановка супервизором убила бы
    # процесс посреди транзакции, и вызывающий получил бы exit вместо исхода команды.
    Process.flag(:trap_exit, true)
    server = struct!(__MODULE__, args)
    :ok = emit(server, :start, %{})

    Logger.debug("процесс агрегата: запущен: type=#{server.cfg.type} aggregate_id=#{server.aggregate_id}")

    {:ok, server, server.idle_timeout}
  end

  @doc false
  @spec handle_call({:execute, request()}, GenServer.from(), t()) ::
          {:reply, reply(), t(), pos_integer()} | {:noreply, t(), pos_integer()}

  @impl true
  def handle_call({:execute, request}, _from, %__MODULE__{} = server) do
    queue = System.monotonic_time() - request.enqueued_at

    if expired?(request.target.deadline),
      do: dropped(server),
      else: run_command(server, request, queue)
  end

  # ---

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  # Вызывающий по истечении дедлайна уже получил exit и ответа не ждёт; брошенная им команда —
  # признак того, что очередь процесса не успевает.
  defp dropped(server) do
    Logger.warning(
      "процесс агрегата: просроченная команда отброшена: type=#{server.cfg.type} " <>
        "aggregate_id=#{server.aggregate_id}"
    )

    {:noreply, server, server.idle_timeout}
  end

  defp run_command(server, request, queue) do
    now = System.monotonic_time(:millisecond)
    server = drop_stale(server, now)
    read_at = next_read_at(server, now)

    case in_caller_env(server, request) do
      {{:ok, state} = executed, retries} ->
        {:reply, {Execution.result(executed), retries, queue}, %{server | state: state, read_at: read_at},
         server.idle_timeout}

      {:expired, _retries} ->
        dropped(server)

      {{:error, _reason} = error, retries} ->
        {:reply, {error, retries, queue}, server, server.idle_timeout}
    end
  end

  # Состояние старше предела выбрасывается до команды при любом её исходе: команда пойдёт полным
  # чтением, и устаревшая копия в процессе не остаётся.
  defp drop_stale(%__MODULE__{read_at: nil} = server, _now), do: server

  defp drop_stale(server, now) do
    if stale?(server.read_at, now, server.state_max_age) do
      Logger.debug(
        "процесс агрегата: состояние устарело: type=#{server.cfg.type} " <>
          "aggregate_id=#{server.aggregate_id} state_max_age=#{server.state_max_age}"
      )

      %{server | state: nil, read_at: nil}
    else
      server
    end
  end

  # Отметка полного чтения — момент до команды: возраст состояния не занижается. `refresh` её не
  # обновляет: дочитанный хвост не перечитывает ПДн, свёрнутые раньше.
  defp next_read_at(server, now) do
    if Execution.refreshes?(server.state),
      do: server.read_at,
      else: now
  end

  # Окружение вызывающего — только на время команды: OTel-контекст, `Logger.metadata()` и
  # `context` с таблицей `Repo.Sc` процесса вместо приватной таблицы вызывающего.
  defp in_caller_env(server, %{call: call} = request) do
    bind do
      [] <- Otel.with_ctx(request.otel_ctx)
      [] <- with_metadata(request.metadata)
      context <- with_shadow_copy(call.context)
      :ok = Otel.Es.dequeued()
      Execution.run(server.cfg, %{call | context: context}, request.target, server.state)
    end
  end

  defp with_metadata(metadata, fun) do
    own = Logger.metadata()
    :ok = Logger.metadata(metadata)

    try do
      fun.()
    after
      :ok = Logger.reset_metadata(own)
    end
  end

  defp with_shadow_copy(context, fun) do
    context = Repo.Sc.init(context)

    try do
      fun.(context)
    after
      Repo.Sc.delete(context)
    end
  end

  # ===== возраст состояния =====

  @doc """
  Состояние устарело: от полного чтения `read_at` до `now` (мс монотонного времени) прошло больше
  `max_age`; при `:infinity` — никогда.
  """
  @spec stale?(integer(), integer(), pos_integer() | :infinity) :: boolean()

  def stale?(read_at, now, :infinity) when is_integer(read_at) and is_integer(now), do: false

  def stale?(read_at, now, max_age) when is_integer(read_at) and is_integer(now) and is_integer(max_age),
    do: now - read_at > max_age

  # ===== остановка =====

  @doc false
  @spec handle_info(term(), t()) :: {:noreply, t(), pos_integer()} | {:stop, :normal, t()}

  @impl true
  def handle_info(:timeout, %__MODULE__{} = server) do
    :ok = emit(server, :stop, %{reason: :idle})

    Logger.debug(
      "процесс агрегата: ушёл по простою: type=#{server.cfg.type} " <>
        "aggregate_id=#{server.aggregate_id} idle_timeout=#{server.idle_timeout}"
    )

    {:stop, :normal, server}
  end

  def handle_info(_message, server), do: {:noreply, server, server.idle_timeout}

  @doc false
  @spec terminate(term(), t()) :: :ok

  @impl true
  def terminate(reason, _server) when reason in ~w(normal shutdown)a, do: :ok
  def terminate({:shutdown, _reason}, _server), do: :ok

  # Исключение в команде: транзакция откатилась, вызывающий получает exit.
  def terminate(_reason, server), do: emit(server, :stop, %{reason: :error})

  # ===== отчёт о падении =====

  @doc false
  @spec format_status(:gen_server.format_status()) :: :gen_server.format_status()

  # Отчёт о падении и `:sys.get_status/1` агрегата с ПДн в событиях: состояние и команда несут ПДн,
  # а извлечённое из Prim значение `Inspect` не скрывает.
  @impl true
  def format_status(%{state: %__MODULE__{cfg: %{personal: true}} = server} = status) do
    status
    |> Map.put(:state, %{type: server.cfg.type, aggregate_id: server.aggregate_id, version: version(server.state)})
    |> Map.replace_lazy(:message, &command_module/1)
  end

  def format_status(status), do: status

  # ---

  defp version(%{version: version}), do: version
  defp version(nil), do: nil

  defp command_module({:execute, %{call: %{command: %{__struct__: command}}}}), do: command

  defp command_module(message), do: message

  # ===== общее =====

  defp emit(server, event, metadata) do
    :telemetry.execute(
      Telemetry.event([:es, :aggregate, :process, event]),
      %{},
      Map.put(metadata, :type, server.cfg.type)
    )
  end
end
