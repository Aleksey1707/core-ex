defmodule Consumer.Domain.Sales.Itinerary do
  @moduledoc """
  Синтетический агрегат «шаги маршрута»: проверочный сценарий Core, а не адаптация потребителя.

  Нагрузка события — `steps: [list: [entity: Step]]`; у шага открытые `channel` / `status` /
  `attempts` и ПДн-места `recipient` / `content` (Prim с `personal: true`, субъект по умолчанию
  `:aggregate_id`). Состояние и команда — структуры по полям: у шага два типа — чтения (`Step.t()`,
  с `%Core.Es.Personal.Destroyed{}` на ПДн-местах) и записи (`Step.write_t()`).
  """

  alias Consumer.Domain.Sales.Itinerary.Cmd
  alias Consumer.Domain.Sales.Itinerary.Errors
  alias Consumer.Domain.Sales.Itinerary.Event
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Itinerary.Event.Codec

  defmodule ID do
    @moduledoc "Идентификатор маршрута."

    use Core.Prim.UUID,
      name: "Маршрут",
      version: 7
  end

  defmodule Recipient do
    @moduledoc "Получатель шага — ПДн."

    use Core.Prim.String,
      name: "Получатель шага",
      min_len: 1,
      max_len: 100,
      personal: true
  end

  defmodule Content do
    @moduledoc "Содержимое шага — ПДн."

    use Core.Prim.String,
      name: "Содержимое шага",
      min_len: 1,
      max_len: 200,
      personal: true
  end

  defmodule Channel do
    @moduledoc """
    Канал доставки шага

    | Значение | Описание |
    |---|---|
    | `:email` | электронная почта |
    | `:sms` | сообщение |
    | `:push` | push-уведомление |
    """

    use Core.Enum,
      name: "Канал доставки",
      values: ~w(email sms push)a
  end

  defmodule Status do
    @moduledoc """
    Статус шага

    | Значение | Описание |
    |---|---|
    | `:planned` | шаг запланирован |
    | `:sent` | шаг отправлен |
    | `:failed` | отправка не удалась |
    """

    use Core.Enum,
      name: "Статус шага",
      values: ~w(planned sent failed)a
  end

  use Core.Struct,
    fields: [
      id: [prim: ID],
      version: [prim: Version, optional: true],
      steps: [list: [entity: Consumer.Domain.Sales.Itinerary.Step], default: []]
    ]

  @impl true
  def decide(%Cmd.Plan{steps: steps}, %__MODULE__{version: nil}),
    do: {:ok, [Event.Planned.draft(Event.Planned.Payload.new(steps))]}

  def decide(%Cmd.Plan{}, %__MODULE__{}), do: {:error, Errors.domain(__MODULE__, :already_exists, nil)}

  @impl true
  def evolve(state, %Event.Planned{payload: %Event.Planned.Payload{} = payload}),
    do: %{state | steps: payload.steps}
end
