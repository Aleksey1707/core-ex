defmodule Core.Es.Aggregate do
  @moduledoc """
  Builder event-sourced агрегата (`use`) и его behaviour.

      defmodule MyApp.Domain.<BC>.Common.Account do
        use Core.Es.Aggregate,
          event_codec: MyApp.Domain.<BC>.Common.Account.Event.Codec

        defstruct id: nil, version: nil, name: nil, status: nil

        @impl true
        def decide(%Cmd.Rename{name: name}, %__MODULE__{name: name}), do: {:ok, []}

        def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
          do: {:ok, [Event.Codec.draft(Event.Renamed, Event.Renamed.Payload.new(name))]}

        @impl true
        def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}
      end

  Автор пишет два колбэка, библиотека — свёртку событий и шаг исполнения команды.

  ## Колбэки

  - `decide(command, state)` → `{:ok, [result]} | {:error, Error.t()}` — решение по команде
    (`use Core.Es.Cmd`). Элемент результата — черновик события от кодека агрегата:
    `Event.Codec.draft(Event.Mod, payload)` или `Event.Codec.draft(Event.Mod)` у события без
    нагрузки (`Core.Es.Event.Codec`, «Черновик события»); `{:ok, []}` — команда без изменений.
    Агрегата ещё нет — `version: nil`: `:not_found` / `:already_exists` решает `decide` доменной
    ошибкой.
  - `evolve(state, event)` → состояние — применение события: чистый, без проверки инвариантов и
    без catch-all, голова матчит только событие. `id` и `version` результата библиотека
    перезаписывает.

  ## Состояние

  `id` и `version` — обязательные поля `defstruct`, иначе `CompileError`; ведёт их только
  библиотека. Начальное состояние — `%Agg{id: id}` с `id` из адреса вызова, «не создан» —
  `version: nil`.

  ## Генерируемые функции

  - `fold(state, events)` → `%Agg{}` — свёртка истории от любого состояния: версии событий идут
    подряд от `state.version`, `aggregate_id` равен `state.id`; разрыв версий или чужой
    `aggregate_id` — `ArgumentError`;
  - `fold(state, command, results)` → `%Agg{}` — свёртка результата `decide/2`: несколько событий
    одной команды автор сворачивает через `with`, чтобы следующее решение видело состояние после
    предыдущего;
  - `execute(state, command)` → `{:ok, {[Es.Event], %Agg{}}} | {:error, Error.t()}` — чистый шаг
    «`decide/2` → события → `fold/2`»; `{:ok, []}` даёт `{:ok, {[], state}}` без роста версии;
  - `__es_event_codec__/0` — кодек событий агрегата.

  Головы принимают только `%Agg{}`, результат сужен до формы выше: компилятор у вызывающего знает
  состояние агрегата, и опечатка в его поле или невозможная clause по результату — предупреждение
  при сборке. `execute/2` зовёт `decide(command, state)` в модуле агрегата, поэтому домен команды
  — clauses `decide/2`: команда другого агрегата или без clause в `decide` ловится при сборке.

  События результата `decide/2` собираются так: `id` — новый, `aggregate_id` — `state.id`,
  `aggregate_version` — по порядку от `state.version` (от `nil` — с 1), `by` и `at` — поля
  команды. Модуль события не из `__es_mods__/0` кодека — `FunctionClauseError`; `by` или `at` не
  того Prim — `FunctionClauseError` конструктора события.

  ## Opts

  - `event_codec:` — кодек событий агрегата (`use Core.Es.Event.Codec`). На компиляции не
    загружается: события ссылаются на Prim агрегата, и загрузка кодека замкнула бы цикл
    агрегат → кодек → события → `Agg.ID`. Полноту `evolve` по кодеку проверяет при сборке
    репозиторий агрегата (`Core.Es.Aggregate.Repo`, «Полнота `evolve`»); агрегат без
    репозитория не проверяется.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Helper
  alias Core.Version

  @label "Es.Aggregate"
  @required_keys ~w(event_codec)a
  @optional_keys []
  @state_keys ~w(id version)a

  @typedoc "Черновик события — элемент результата `decide/2`: `{Event.Mod, payload}` или `Event.Mod`."
  @type result :: {module(), struct()} | module()

  @doc "Решение по команде: события, которые случатся, или доменный отказ."
  @callback decide(command :: struct(), state :: struct()) ::
              {:ok, [result()]} | {:error, Error.t()}

  @doc "Применение события к состоянию."
  @callback evolve(state :: struct(), event :: Es.Event.t()) :: struct()

  # ===== объявление =====

  @doc "Объявить event-sourced агрегат."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    event_codec = Helper.Opts.atom!(lit, :event_codec, @label)

    quote generated: true do
      @behaviour Core.Es.Aggregate
      @after_compile Core.Es.Aggregate

      @doc false
      @spec __es_event_codec__() :: module()

      def __es_event_codec__, do: unquote(event_codec)

      @doc "Свернуть события истории от состояния `state`."
      @spec fold(%__MODULE__{}, [Core.Es.Event.t()]) :: %__MODULE__{}

      def fold(%__MODULE__{} = state, events) when is_list(events) do
        %__MODULE__{} = folded = Core.Es.Aggregate.fold(__MODULE__, state, events)
        folded
      end

      @doc "Свернуть результат `decide/2` по команде `command` от состояния `state`."
      @spec fold(%__MODULE__{}, struct(), [Core.Es.Aggregate.result()]) :: %__MODULE__{}

      def fold(%__MODULE__{} = state, command, results) when is_list(results) do
        %__MODULE__{} = folded = Core.Es.Aggregate.fold(__MODULE__, state, command, results)
        folded
      end

      @doc "Исполнить команду: события решения `decide/2` и состояние после них."
      @spec execute(%__MODULE__{}, struct()) ::
              {:ok, {[Core.Es.Event.t()], %__MODULE__{}}} | {:error, Core.Error.t()}

      def execute(%__MODULE__{} = state, command) when is_struct(command) do
        case Core.Es.Aggregate.apply_decision(__MODULE__, state, command, decide(command, state)) do
          {:ok, {events, %__MODULE__{} = executed}} when is_list(events) -> {:ok, {events, executed}}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok

  def __after_compile__(env, _bytecode) do
    fields = for %{field: field} <- env.module.__info__(:struct) || [], do: field

    case @state_keys -- fields do
      [] ->
        :ok

      missing ->
        raise CompileError,
          description:
            "#{@label}: #{inspect(env.module)} обязан объявить #{inspect(@state_keys)} в " <>
              "defstruct — их ведёт библиотека; нет #{inspect(missing)}",
          file: env.file,
          line: env.line
    end
  end

  # ===== команда =====

  @doc false
  @spec apply_decision(module(), struct(), struct(), {:ok, [result()]} | {:error, Error.t()}) ::
          {:ok, {[Es.Event.t()], struct()}} | {:error, Error.t()}

  def apply_decision(aggregate, state, %{by: by, at: at} = command, decision)
      when is_struct(state, aggregate) and is_struct(command) do
    case decision do
      {:ok, results} when is_list(results) ->
        events = events(aggregate, state, results, by, at)
        {:ok, {events, fold(aggregate, state, events)}}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc false
  @spec fold(module(), struct(), struct(), [result()]) :: struct()

  def fold(aggregate, state, %{by: by, at: at} = command, results)
      when is_struct(state, aggregate) and is_struct(command) and is_list(results) do
    fold(aggregate, state, events(aggregate, state, results, by, at))
  end

  @doc false
  @spec fold(module(), struct(), [Es.Event.t()]) :: struct()

  def fold(aggregate, state, events) when is_struct(state, aggregate) and is_list(events),
    do: Enum.reduce(events, state, &step(aggregate, &2, &1))

  # ---

  defp step(aggregate, %{id: id} = state, %{aggregate_id: id, aggregate_version: version} = event) do
    expected = next_version(state.version)

    if version != expected do
      raise ArgumentError,
            "#{@label}: разрыв версий в свёртке #{inspect(aggregate)} #{inspect(id)}: " <>
              "ожидалась #{Version.value(expected)}, пришла #{Version.value(version)}"
    end

    %{__struct__: ^aggregate} = evolved = aggregate.evolve(state, event)
    %{evolved | id: id, version: version}
  end

  defp step(aggregate, state, %{aggregate_id: _} = event) do
    raise ArgumentError,
          "#{@label}: событие чужого агрегата в свёртке #{inspect(aggregate)} " <>
            "#{inspect(state.id)}: aggregate_id #{inspect(event.aggregate_id)}"
  end

  # ===== события =====

  @doc false
  @spec events(module(), struct(), [result()], struct(), Es.Event.At.t()) :: [Es.Event.t()]

  def events(aggregate, state, results, by, at)
      when is_struct(state, aggregate) and is_list(results) do
    mods = Map.from_keys(aggregate.__es_event_codec__().__es_mods__(), true)

    {events, _version} =
      Enum.map_reduce(results, state.version, fn result, version ->
        next = next_version(version)
        {event(result, mods, state.id, next, by, at), next}
      end)

    events
  end

  # ---

  defp event({mod, payload}, mods, id, version, by, at) when is_map_key(mods, mod),
    do: mod.new(payload, id, version, by, at)

  defp event(mod, mods, id, version, by, at) when is_map_key(mods, mod),
    do: mod.new(id, version, by, at)

  # ===== общее =====

  defp next_version(nil), do: Version.new()
  defp next_version(%Version{} = version), do: Version.next(version)
end
