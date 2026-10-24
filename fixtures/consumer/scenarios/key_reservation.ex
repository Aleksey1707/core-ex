defmodule ConsumerTest.BadKey do
  @moduledoc "Модуль ключа без clause `reservation/1` для `Closed`."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Account.Event

  # нет clause `reservation/1` для `Closed`: проверка полноты на строке `use` ключа
  # expect: incompatible types given to reservation/1
  use Core.Es.KeyReservation,
    scope: "scenario.bad_key",
    aggregate: Account,
    code: :name_taken

  @impl true
  def reservation(%Event.Opened{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Renamed{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.HolderSet{}), do: :keep
  def reservation(%Event.Frozen{}), do: :keep

  @impl true
  def to_key(%Account.Name{} = name), do: Account.Name.value(name)
end

defmodule ConsumerTest.BadKeyPayload do
  @moduledoc "Модуль ключа с опечаткой в поле нагрузки, не суженной паттерном."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Account.Event

  # опечатка в поле нагрузки без паттерна `%Payload{}`: при определении молчит
  # expect: incompatible types given to reservation/1
  use Core.Es.KeyReservation,
    scope: "scenario.bad_key_payload",
    aggregate: Account,
    code: :name_taken

  @impl true
  def reservation(%Event.Opened{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Renamed{payload: payload}), do: {:reserve, payload.nmae}
  def reservation(%Event.HolderSet{}), do: :keep
  def reservation(%Event.Frozen{}), do: :keep
  def reservation(%Event.Closed{}), do: :release

  @impl true
  def to_key(%Account.Name{} = name), do: Account.Name.value(name)
end

defmodule ConsumerTest.KeyFind do
  @moduledoc "Вызовы генерируемого `find/2` модуля ключа."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Order
  alias Core.Context

  # `{:ok, _}` по результату `find`
  def case_find_ok(%Account.Name{} = name, %Context{} = context) do
    case Account.NameKey.find(name, context) do
      # expect: the following clause will never match
      {:ok, id} -> id
      _free -> nil
    end
  end

  # `{:ok, _}` по результату `find` модуля ключа из ПДн: сужение то же, что без `personal: true`
  def case_holder_find_ok(%Account.Holder{} = holder, %Context{} = context) do
    case Account.HolderKey.find(holder, context) do
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
    # expect: incompatible types given to Consumer.Domain.Sales.Account.NameKey.find/2
    do: Account.NameKey.find(name, %{})
end
