defmodule Core.EsFixture.Itinerary do
  @moduledoc """
  Синтетический event-sourced агрегат «шаги маршрута»: нагрузка события — `steps: [list: [entity: Step]]`,
  у шага открытые `channel` / `status` / `attempts` и ПДн-места `recipient` / `content`
  (Prim с `personal: true`) с субъектом по умолчанию `:aggregate_id`.

  Демонстрирует рекурсивное шифрование ПДн: маркеры и `{"$pd": …}` стоят на каждом месте шага,
  открытая часть списка остаётся открытой.
  """

  alias Core.Es
  alias Core.EsFixture.Itinerary.Cmd
  alias Core.EsFixture.Itinerary.Errors
  alias Core.EsFixture.Itinerary.Event
  alias Core.Result
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Core.EsFixture.Itinerary.Event.Codec

  defmodule ID do
    @moduledoc "Идентификатор маршрута."

    use Core.Prim.UUID,
      name: "Идентификатор маршрута",
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

  defmodule Step do
    @moduledoc "Шаг маршрута: открытые поля и два ПДн-места."

    use Core.Struct,
      fields: [
        channel: [type: :string],
        status: [type: :string],
        attempts: [type: :non_neg_integer],
        recipient: [prim: Core.EsFixture.Itinerary.Recipient],
        content: [prim: Core.EsFixture.Itinerary.Content]
      ]

    use Core.Labels.Fields,
      labels: [
        channel: "Канал",
        status: "Статус",
        attempts: "Попытки",
        recipient: "Получатель",
        content: "Содержимое"
      ]
  end

  defmodule Step.Codec do
    @moduledoc "Плагин шага маршрута — из общей декларации."

    use Core.Codec.Plugin, types: [Core.EsFixture.Itinerary.Step]
  end

  defstruct id: nil, version: nil, steps: []

  @type t :: %__MODULE__{
          id: ID.t() | nil,
          version: Version.t() | nil,
          steps: [Step.t()]
        }

  # ===== decide =====

  @doc "Решение по команде маршрута."
  @spec decide(Cmd.t(), t()) :: Result.t([Es.Aggregate.result()])

  @impl true
  def decide(%Cmd.Plan{steps: steps}, %__MODULE__{version: nil}),
    do: {:ok, [Event.Planned.draft(Event.Planned.Payload.new(steps))]}

  def decide(%Cmd.Plan{}, %__MODULE__{}), do: {:error, Errors.domain(__MODULE__, :already_exists, nil)}

  # ===== evolve =====

  @doc "Применение события маршрута."
  @spec evolve(t(), Event.t()) :: t()

  @impl true
  def evolve(state, %Event.Planned{payload: payload}), do: %{state | steps: payload.steps}
  def evolve(state, %Event.RecipientChanged{}), do: state
  def evolve(state, %Event.StepRecorded{}), do: state
end
