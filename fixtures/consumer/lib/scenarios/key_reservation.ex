defmodule Consumer.S.BadKey do
  @moduledoc "Модуль ключа без clause `reservation/1` для `Closed`."

  alias Consumer.Account
  alias Consumer.Account.Event

  use Core.Es.KeyReservation,
    scope: "scenario.bad_key",
    event: Account.Event,
    id: Account.ID,
    code: :name_taken

  @impl true
  def reservation(%Event.Opened{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Renamed{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Frozen{}), do: :keep

  @impl true
  def to_key(%Account.Name{} = name), do: Account.Name.value(name)
end

defmodule Consumer.S.BadKey.Repo.Pg do
  @moduledoc "Репозиторий с модулем ключа без clause `reservation/1` для `Closed`."

  alias Consumer.Account

  # нет clause `reservation/1` для `Closed`: проверка полноты на строке `use`
  # expect: incompatible types given to Consumer.S.BadKey.reservation/1
  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    key_reservations: [Consumer.S.BadKey]
end

defmodule Consumer.S.BadKeyPayload do
  @moduledoc "Модуль ключа с опечаткой в поле нагрузки, не суженной паттерном."

  alias Consumer.Account
  alias Consumer.Account.Event

  use Core.Es.KeyReservation,
    scope: "scenario.bad_key_payload",
    event: Account.Event,
    id: Account.ID,
    code: :name_taken

  @impl true
  def reservation(%Event.Opened{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Renamed{payload: payload}), do: {:reserve, payload.nmae}
  def reservation(%Event.Frozen{}), do: :keep
  def reservation(%Event.Closed{}), do: :release

  @impl true
  def to_key(%Account.Name{} = name), do: Account.Name.value(name)
end

defmodule Consumer.S.BadKeyPayload.Repo.Pg do
  @moduledoc "Репозиторий с модулем ключа с опечаткой в поле нагрузки."

  alias Consumer.Account

  # опечатка в поле нагрузки без паттерна `%Payload{}`: при определении молчит
  # expect: incompatible types given to Consumer.S.BadKeyPayload.reservation/1
  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    key_reservations: [Consumer.S.BadKeyPayload]
end

defmodule Consumer.S.KeyFind do
  @moduledoc "Вызовы генерируемого `find/2` модуля ключа."

  alias Consumer.Account
  alias Consumer.Order
  alias Core.Context

  # `{:ok, _}` по результату `find`
  def case_find_ok(%Account.Name{} = name, %Context{} = context) do
    case Account.NameKey.find(name, context) do
      # expect: the following clause will never match
      {:ok, id} -> id
      _free -> nil
    end
  end

  # ID другого агрегата по результату `find`
  def case_find_foreign_id(%Account.Name{} = name, %Context{} = context) do
    case Account.NameKey.find(name, context) do
      # expect: the following clause will never match
      %Order.ID{} = id -> id
      _free -> nil
    end
  end

  # не `%Context{}` вторым аргументом
  def find_not_context(%Account.Name{} = name),
    # expect: incompatible types given to Consumer.Account.NameKey.find/2
    do: Account.NameKey.find(name, %{})
end
