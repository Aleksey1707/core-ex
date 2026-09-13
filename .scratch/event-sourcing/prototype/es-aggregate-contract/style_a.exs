# PROTOTYPE — стиль A «Мутация записывает событие».
# Автор домена пишет мутации как у state-stored агрегата: {:ok, draft} | {:error, _}.
# Состояние меняет только apply_event/2 — и внутри мутации (через record/5), и при восстановлении.

defmodule ProtoA.Draft do
  alias Proto.Draft.Errors
  alias Proto.Draft.Event
  alias Proto.Draft.Title

  use Proto.Es.Aggregate

  defstruct id: nil, version: nil, title: nil, status: nil, events: []

  # ===== мутации =====

  def create(%Proto.Draft.ID{} = id, %Title{} = title, by, at),
    do: {:ok, id |> start() |> record(Event.Created, Event.Created.Payload.new(title), by, at)}

  def rename(%__MODULE__{title: title} = draft, %Title{} = title, _by, _at), do: {:ok, draft}

  def rename(%__MODULE__{status: :new} = draft, %Title{} = title, by, at),
    do: {:ok, record(draft, Event.Renamed, Event.Renamed.Payload.new(title), by, at)}

  def rename(draft, _title, _by, _at), do: {:error, Errors.invalid_status(draft, :rename)}

  def submit(%__MODULE__{status: :new} = draft, auto_approve?, by, at) do
    draft = record(draft, Event.Submitted, nil, by, at)

    if auto_approve?,
      do: approve(draft, by, at),
      else: {:ok, draft}
  end

  def submit(draft, _auto_approve?, _by, _at), do: {:error, Errors.invalid_status(draft, :submit)}

  def approve(%__MODULE__{status: :in_approving} = draft, by, at),
    do: {:ok, record(draft, Event.Approved, nil, by, at)}

  def approve(draft, _by, _at), do: {:error, Errors.invalid_status(draft, :approve)}

  # ===== применение события =====

  @impl true
  def apply_event(draft, %Event.Created{payload: payload}), do: %{draft | title: payload.title, status: :new}
  def apply_event(draft, %Event.Renamed{payload: payload}), do: %{draft | title: payload.title}
  def apply_event(draft, %Event.Submitted{}), do: %{draft | status: :in_approving}
  def apply_event(draft, %Event.Approved{}), do: %{draft | status: :approved}
end

defmodule ProtoA.Repo do
  @moduledoc "PROTOTYPE: заглушка write-репозитория стиля A (её сгенерировала бы библиотека)."

  alias Core.Es.Events
  alias Core.Version
  alias Proto.Draft.Errors
  alias Proto.Store
  alias ProtoA.Draft

  def get(store, id, expected) do
    case Draft.from_events(Store.read(store, id)) do
      {:ok, draft} -> with :ok <- Store.check_version(draft, expected), do: {:ok, draft}
      {:error, :empty_stream} -> {:error, Errors.not_found()}
    end
  end

  def save(store, %Draft{} = draft) do
    events = Events.to_list(draft.events)

    with :ok <- Store.append(store, draft.id, expected_version(events), events),
         do: {:ok, %{draft | events: Events.clear(draft.events)}}
  end

  defp expected_version([%{aggregate_version: %Version{value: 1}} | _]), do: nil
  defp expected_version([%{aggregate_version: %Version{value: value}} | _]), do: Version.new!(value - 1)
  defp expected_version([]), do: nil
end

defmodule ProtoA.Usecase do
  @moduledoc "PROTOTYPE: usecase стиля A — так же, как у state-stored агрегата сейчас."

  alias ProtoA.Draft
  alias ProtoA.Repo

  def create(store, id, title, by, at) do
    with {:ok, draft} <- Draft.create(id, title, by, at),
         {:ok, _draft} <- Repo.save(store, draft),
         do: :ok
  end

  def rename(store, id, version, title, by, at), do: mutate(store, id, version, &Draft.rename(&1, title, by, at))

  def submit(store, id, version, auto_approve?, by, at),
    do: mutate(store, id, version, &Draft.submit(&1, auto_approve?, by, at))

  def approve(store, id, version, by, at), do: mutate(store, id, version, &Draft.approve(&1, by, at))

  defp mutate(store, id, version, mutation) do
    with {:ok, draft} <- Repo.get(store, id, version),
         {:ok, draft} <- mutation.(draft),
         {:ok, _draft} <- Repo.save(store, draft),
         do: :ok
  end
end

defmodule ProtoA.Driver do
  @moduledoc "PROTOTYPE: единый интерфейс сценариев для стиля A."

  alias ProtoA.Draft
  alias ProtoA.Repo
  alias ProtoA.Usecase

  def name, do: "A · мутация записывает событие"

  def usecase(store, id, _version, {:create, title}), do: Usecase.create(store, id, title, by(), at())
  def usecase(store, id, version, {:rename, title}), do: Usecase.rename(store, id, version, title, by(), at())
  def usecase(store, id, version, {:submit, auto?}), do: Usecase.submit(store, id, version, auto?, by(), at())
  def usecase(store, id, version, :approve), do: Usecase.approve(store, id, version, by(), at())

  def load(store, id), do: Repo.get(store, id, :current)

  def raw(draft, {:rename, title}), do: Draft.rename(draft, title, by(), at())
  def raw(draft, {:submit, auto?}), do: Draft.submit(draft, auto?, by(), at())
  def raw(draft, :approve), do: Draft.approve(draft, by(), at())

  def prepare(draft, action), do: raw(draft, action)
  def pending_events(draft), do: Core.Es.Events.to_list(draft.events)
  def pending_state(draft), do: %{draft | events: Core.Es.Events.clear(draft.events)}
  def commit(store, draft), do: Repo.save(store, draft)

  def fold_empty, do: Draft.from_events([])

  defp by, do: Proto.User.ID.new()
  defp at, do: Core.Es.Event.At.now!()
end
