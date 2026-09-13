# PROTOTYPE — стиль B «Decider».
# Автор домена пишет три функции: initial_state/0, decide(команда, состояние) → события | ошибка,
# evolve(состояние, событие) → состояние. Команды — структуры, событий в состоянии нет.

defmodule ProtoB.Draft do
  alias Proto.Draft.Errors
  alias Proto.Draft.Event

  use Proto.Es.Decider

  defstruct id: nil, version: nil, title: nil, status: nil

  defmodule Cmd do
    defmodule Create do
      @enforce_keys ~w(id title by at)a
      defstruct @enforce_keys
    end

    defmodule Rename do
      @enforce_keys ~w(title by at)a
      defstruct @enforce_keys
    end

    defmodule Submit do
      @enforce_keys ~w(auto_approve? by at)a
      defstruct @enforce_keys
    end

    defmodule Approve do
      @enforce_keys ~w(by at)a
      defstruct @enforce_keys
    end
  end

  @impl true
  def initial_state, do: %__MODULE__{}

  # ===== decide =====

  @impl true
  def decide(%Cmd.Create{} = cmd, %__MODULE__{version: nil} = state),
    do: {:ok, stamp(state, [{Event.Created, Event.Created.Payload.new(cmd.title)}], cmd)}

  def decide(%Cmd.Create{}, state), do: {:error, Errors.already_exists(state)}

  def decide(_cmd, %__MODULE__{version: nil}), do: {:error, Errors.not_found()}

  def decide(%Cmd.Rename{title: title}, %__MODULE__{title: title}), do: {:ok, []}

  def decide(%Cmd.Rename{} = cmd, %__MODULE__{status: :new} = state),
    do: {:ok, stamp(state, [{Event.Renamed, Event.Renamed.Payload.new(cmd.title)}], cmd)}

  def decide(%Cmd.Submit{auto_approve?: false} = cmd, %__MODULE__{status: :new} = state),
    do: {:ok, stamp(state, [{Event.Submitted, nil}], cmd)}

  def decide(%Cmd.Submit{auto_approve?: true} = cmd, state) do
    # Approved проверяется по состоянию после Submitted — decide его не видит, свернуть вручную
    with {:ok, submitted} <- decide(%{cmd | auto_approve?: false}, state),
         {:ok, approved} <- decide(%Cmd.Approve{by: cmd.by, at: cmd.at}, fold(state, submitted)) do
      {:ok, submitted ++ approved}
    end
  end

  def decide(%Cmd.Approve{} = cmd, %__MODULE__{status: :in_approving} = state),
    do: {:ok, stamp(state, [{Event.Approved, nil}], cmd)}

  def decide(%{__struct__: command}, state), do: {:error, Errors.invalid_status(state, command)}

  # ===== evolve =====

  @impl true
  def evolve(state, %Event.Created{payload: payload}), do: %{state | title: payload.title, status: :new}
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | title: payload.title}
  def evolve(state, %Event.Submitted{}), do: %{state | status: :in_approving}
  def evolve(state, %Event.Approved{}), do: %{state | status: :approved}
end

defmodule ProtoB.Repo do
  @moduledoc "PROTOTYPE: заглушка репозитория стиля B (её сгенерировала бы библиотека)."

  alias Proto.Store
  alias ProtoB.Draft

  def get(store, id, expected) do
    state = Draft.fold(Draft.initial_state(), Store.read(store, id))

    with :ok <- Store.check_version(state, expected), do: {:ok, state}
  end

  def append(store, id, expected, events), do: Store.append(store, id, expected, events)
end

defmodule ProtoB.Usecase do
  @moduledoc "PROTOTYPE: usecase стиля B — одна функция на все команды."

  alias ProtoB.Draft
  alias ProtoB.Draft.Cmd
  alias ProtoB.Repo

  def create(store, id, title, by, at),
    do: execute(store, id, :current, %Cmd.Create{id: id, title: title, by: by, at: at})

  def rename(store, id, version, title, by, at),
    do: execute(store, id, version, %Cmd.Rename{title: title, by: by, at: at})

  def submit(store, id, version, auto_approve?, by, at),
    do: execute(store, id, version, %Cmd.Submit{auto_approve?: auto_approve?, by: by, at: at})

  def approve(store, id, version, by, at), do: execute(store, id, version, %Cmd.Approve{by: by, at: at})

  def execute(store, id, version, command) do
    with {:ok, state} <- Repo.get(store, id, version),
         {:ok, events} <- Draft.decide(command, state),
         do: Repo.append(store, id, state.version, events)
  end
end

defmodule ProtoB.Driver do
  @moduledoc "PROTOTYPE: единый интерфейс сценариев для стиля B."

  alias ProtoB.Draft
  alias ProtoB.Draft.Cmd
  alias ProtoB.Repo
  alias ProtoB.Usecase

  def name, do: "B · decider"

  def usecase(store, id, _version, {:create, title}), do: Usecase.create(store, id, title, by(), at())
  def usecase(store, id, version, {:rename, title}), do: Usecase.rename(store, id, version, title, by(), at())
  def usecase(store, id, version, {:submit, auto?}), do: Usecase.submit(store, id, version, auto?, by(), at())
  def usecase(store, id, version, :approve), do: Usecase.approve(store, id, version, by(), at())

  def load(store, id), do: Repo.get(store, id, :current)

  def raw(state, {:rename, title}), do: Draft.decide(%Cmd.Rename{title: title, by: by(), at: at()}, state)
  def raw(state, {:submit, auto?}), do: Draft.decide(%Cmd.Submit{auto_approve?: auto?, by: by(), at: at()}, state)
  def raw(state, :approve), do: Draft.decide(%Cmd.Approve{by: by(), at: at()}, state)

  def prepare(state, action), do: with({:ok, events} <- raw(state, action), do: {:ok, {state, events}})
  def pending_events({_state, events}), do: events
  def pending_state({state, events}), do: Draft.fold(state, events)
  def commit(store, {state, events}), do: Repo.append(store, state.id, state.version, events)

  def fold_empty, do: {:ok, Draft.fold(Draft.initial_state(), [])}

  defp by, do: Proto.User.ID.new()
  defp at, do: Core.Es.Event.At.now!()
end
