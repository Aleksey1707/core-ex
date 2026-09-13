# PROTOTYPE — одноразовый код тикета «Контракт event-sourced агрегата» (.scratch/event-sourcing).
# Общая часть обоих стилей: типы черновика, события, ошибки, «библиотека» (Proto.Es*),
# хранилище событий в памяти и печать. Не образец стиля и не кандидат в lib/.

defmodule Proto.Draft.ID do
  @moduledoc "Идентификатор черновика"

  use Core.Prim.UUID,
    name: "Идентификатор черновика",
    version: 7
end

defmodule Proto.User.ID do
  @moduledoc "Идентификатор пользователя"

  use Core.Prim.UUID,
    name: "Идентификатор пользователя",
    version: 7
end

defmodule Proto.Draft.Title do
  @moduledoc "Название черновика"

  use Core.Prim.String,
    name: "Название черновика",
    min_len: 1,
    max_len: 100
end

defmodule Proto.Draft.Event do
  @moduledoc "События черновика — одни и те же для обоих стилей."

  defmodule Created do
    defmodule Payload do
      @enforce_keys ~w(title)a
      defstruct @enforce_keys

      def new(%Proto.Draft.Title{} = title), do: %__MODULE__{title: title}
    end

    use Core.Es.Event,
      aggregate_id: Proto.Draft.ID,
      by: Proto.User.ID,
      payload: Payload
  end

  defmodule Renamed do
    defmodule Payload do
      @enforce_keys ~w(title)a
      defstruct @enforce_keys

      def new(%Proto.Draft.Title{} = title), do: %__MODULE__{title: title}
    end

    use Core.Es.Event,
      aggregate_id: Proto.Draft.ID,
      by: Proto.User.ID,
      payload: Payload
  end

  defmodule Submitted do
    use Core.Es.Event,
      aggregate_id: Proto.Draft.ID,
      by: Proto.User.ID,
      payload: nil
  end

  defmodule Approved do
    use Core.Es.Event,
      aggregate_id: Proto.Draft.ID,
      by: Proto.User.ID,
      payload: nil
  end
end

defmodule Proto.Draft.Errors do
  @moduledoc "Доменные ошибки черновика."

  alias Core.Error
  alias Core.Version

  require Error

  def not_found, do: error(:not_found, "Черновик не найден", nil)

  def already_exists(state),
    do: error(:already_exists, "Черновик уже существует", %{version: value(state.version)})

  def invalid_status(state, action),
    do: error(:invalid_status, "Операция недоступна в статусе", %{status: state.status, action: action})

  def version_mismatch(expected, actual),
    do: error(:version_mismatch, "Версия не совпадает", %{expected: value(expected), actual: value(actual)})

  defp error(code, message, detail),
    do: Error.domain(__MODULE__, code: code, ns: :draft, message: message, detail: detail)

  defp value(nil), do: nil
  defp value(%Version{value: value}), do: value
end

defmodule Proto.Es do
  @moduledoc """
  PROTOTYPE: то, что библиотека дала бы обоим стилям.

  Версию события назначает библиотека (следующая за версией состояния), а id и версию
  в состоянии выставляет применение события — агрегат `Version` не трогает.
  """

  alias Core.Version

  def build(event_mod, payload, id, version, by, at) do
    next = next_version(version)

    if is_nil(event_mod.__es_payload__()),
      do: event_mod.new(id, next, by, at),
      else: event_mod.new(payload, id, next, by, at)
  end

  def step(state, event, evolve) do
    expected = next_version(state.version)

    if event.aggregate_version != expected do
      raise "разрыв истории: ожидалась версия #{expected.value}, пришла #{event.aggregate_version.value}"
    end

    state
    |> evolve.(event)
    |> Map.merge(%{id: event.aggregate_id, version: event.aggregate_version})
  end

  def fold(state, events, evolve), do: Enum.reduce(events, state, &step(&2, &1, evolve))

  defp next_version(nil), do: Version.new()
  defp next_version(%Version{} = version), do: Version.next(version)
end

defmodule Proto.Es.Aggregate do
  @moduledoc "PROTOTYPE: `use` для стиля A — мутация записывает событие и сразу его применяет."

  @callback apply_event(state :: struct(), event :: Core.Es.Event.t()) :: struct()

  defmacro __using__(_opts) do
    quote do
      @behaviour Proto.Es.Aggregate

      @doc "Пустой агрегат с идентификатором — только для мутации-создания."
      def start(id), do: %{struct(__MODULE__) | id: id}

      @doc "Восстановить агрегат из истории."
      def from_events([]), do: {:error, :empty_stream}
      def from_events(events), do: {:ok, Proto.Es.fold(struct(__MODULE__), events, &apply_event/2)}

      defp record(state, event_mod, payload, by, at) do
        event = Proto.Es.build(event_mod, payload, state.id, state.version, by, at)
        state = Proto.Es.step(state, event, &apply_event/2)

        %{state | events: Core.Es.Events.add(state.events, event)}
      end
    end
  end
end

defmodule Proto.Es.Decider do
  @moduledoc "PROTOTYPE: `use` для стиля B — decide / evolve / initial_state."

  @callback initial_state() :: struct()
  @callback decide(command :: struct(), state :: struct()) ::
              {:ok, [Core.Es.Event.t()]} | {:error, Core.Error.t()}
  @callback evolve(state :: struct(), event :: Core.Es.Event.t()) :: struct()

  defmacro __using__(_opts) do
    quote do
      @behaviour Proto.Es.Decider

      @doc "Применить события к состоянию."
      def fold(state, events), do: Proto.Es.fold(state, events, &evolve/2)

      # {модуль события, payload} → события с конвертом; автор и момент — из команды
      defp stamp(state, drafts, command) do
        id = state.id || Map.fetch!(command, :id)

        {events, _version} =
          Enum.map_reduce(drafts, state.version, fn {event_mod, payload}, version ->
            event = Proto.Es.build(event_mod, payload, id, version, command.by, command.at)
            {event, event.aggregate_version}
          end)

        events
      end
    end
  end
end

defmodule Proto.Store do
  @moduledoc "PROTOTYPE: event store в памяти — поток на агрегат, проверка ожидаемой версии при append."

  alias Proto.Draft.Errors

  def start do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    store
  end

  def read(store, id), do: Agent.get(store, &Map.get(&1, id, []))

  def append(_store, _id, _expected, []), do: :ok

  def append(store, id, expected, events) do
    Agent.get_and_update(store, fn streams ->
      stream = Map.get(streams, id, [])
      current = if stream == [], do: nil, else: List.last(stream).aggregate_version

      if current == expected,
        do: {:ok, Map.put(streams, id, stream ++ events)},
        else: {{:error, Errors.version_mismatch(expected, current)}, streams}
    end)
  end

  def check_version(_state, :current), do: :ok
  def check_version(%{version: version}, version), do: :ok
  def check_version(%{version: actual}, expected), do: {:error, Errors.version_mismatch(expected, actual)}
end

defmodule Proto.Show do
  @moduledoc "PROTOTYPE: печать сценариев."

  def intro do
    IO.puts("""
    PROTOTYPE · Контракт event-sourced агрегата

    Вопрос: как для автора домена выглядит event-sourced агрегат в :core.
      A — мутация {:ok, draft} | {:error, _} записывает событие и тут же применяет его (apply_event/2);
      B — decider: decide(команда, состояние) → события, evolve(состояние, событие) → состояние.
    Версию события в обоих стилях назначает библиотека, агрегат Version не трогает.
    Код для сравнения — style_a.exs и style_b.exs; общая «библиотека» и хранилище — common.exs.
    """)
  end

  def scenario(title, watch), do: IO.puts("\n══ #{title}\n   смотреть: #{watch}")

  def style(driver), do: IO.puts("\n  ── #{driver.name()}")

  def line(label, value), do: IO.puts("     #{String.pad_trailing(label, 38)} #{fmt(value)}")

  def stream(store, id), do: line("поток в хранилище", Proto.Store.read(store, id))

  def fmt(:ok), do: ":ok"
  def fmt({:ok, value}), do: "{:ok, #{fmt(value)}}"
  def fmt({:error, %{code: code, message: message} = e}), do: "{:error, :#{code} «#{message}» #{inspect(e.detail)}}"
  def fmt({:error, reason}), do: "{:error, #{inspect(reason)}}"
  def fmt([]), do: "[]"
  def fmt([%{aggregate_version: _} | _] = events), do: "[" <> Enum.map_join(events, ", ", &event/1) <> "]"
  def fmt(%{status: _} = state), do: state(state)
  def fmt(other), do: inspect(other)

  defp state(state) do
    fields =
      "id: #{id(state.id)}, version: #{version(state.version)}, " <>
        "title: #{title(state.title)}, status: #{inspect(state.status)}"

    events = if Map.has_key?(state, :events), do: ", events: #{fmt(Core.Es.Events.to_list(state.events))}", else: ""

    "#{short(state.__struct__)}{#{fields}#{events}}"
  end

  defp event(%{payload: %{title: title}} = event), do: "#{short(event.__struct__)}(#{title(title)}) v#{event.aggregate_version.value}"
  defp event(event), do: "#{short(event.__struct__)} v#{event.aggregate_version.value}"

  defp short(module), do: module |> Module.split() |> Enum.take(-2) |> Enum.join(".")

  defp id(nil), do: "nil"
  defp id(%mod{} = id), do: id |> mod.format(:hex) |> String.slice(-6, 6)

  defp version(nil), do: "nil"
  defp version(version), do: version.value

  defp title(nil), do: "nil"
  defp title(title), do: inspect(title.value)
end
