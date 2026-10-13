defmodule Core.LabelsFixture do
  @moduledoc """
  События и нагрузки с подписями (`Core.Labels.*`): нагрузка по полям всех видов сведений,
  нагрузка с полями Enum, нагрузка-Prim и событие без нагрузки.
  """

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  defmodule Name do
    @moduledoc "Название."

    use Core.Prim.String,
      name: "Название",
      min_len: 1,
      max_len: 50
  end

  defmodule Count do
    @moduledoc "Количество."

    use Core.Prim.Integer,
      name: "Количество",
      min: 0
  end

  defmodule Amount do
    @moduledoc "Сумма."

    use Core.Prim.Decimal,
      name: "Сумма",
      scale: 2
  end

  defmodule Day do
    @moduledoc "День."

    use Core.Prim.Date,
      name: "День"
  end

  defmodule Moment do
    @moduledoc "Момент."

    use Core.Prim.DateTime,
      name: "Момент"
  end

  defmodule Status do
    @moduledoc """
    Статус.

    | Значение | Описание |
    |---|---|
    | `:draft` | черновик |
    | `:active` | действует |
    | `:archived` | убран в архив |
    """

    use Core.Enum,
      name: "Статус",
      values: ~w(draft active archived)a

    use Core.Labels.Values,
      labels: [
        active: "Активна",
        archived: "В архиве",
        draft: "Черновик"
      ]
  end

  defmodule Event do
    @moduledoc false

    defmodule Updated do
      @moduledoc "Событие с нагрузкой по полям: поле каждого вида, необязательное и скрытое."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка по полям."

        use Core.Es.Event.Payload,
          fields: [
            name: [prim: LabelsFixture.Name],
            count: [prim: LabelsFixture.Count],
            amount: [prim: LabelsFixture.Amount, optional: true],
            day: [prim: LabelsFixture.Day],
            moment: [prim: LabelsFixture.Moment],
            note: [type: :string, optional: true],
            urgent: [type: :boolean],
            rank: [type: :pos_integer],
            source: [type: :string]
          ]

        use Core.Labels.Fields,
          labels: [
            name: "Название",
            count: "Количество",
            amount: "Сумма",
            day: "День",
            moment: "Момент",
            note: "Примечание",
            urgent: "Срочно",
            rank: "Ранг",
            source: :hidden
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Запись изменена"
    end

    defmodule StatusChanged do
      @moduledoc "Событие с нагрузкой из полей Enum: обязательное и необязательное."

      defmodule Payload do
        @moduledoc "Нагрузка с полями Enum."

        use Core.Es.Event.Payload,
          fields: [
            status: [enum: Core.LabelsFixture.Status],
            previous: [enum: Core.LabelsFixture.Status, optional: true]
          ]

        use Core.Labels.Fields,
          labels: [
            status: "Статус",
            previous: "Прежний статус"
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Статус сменён"
    end

    defmodule Renamed do
      @moduledoc "Событие с нагрузкой-Prim."

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Core.LabelsFixture.Name

      use Core.Labels.Event,
        title: "Запись переименована",
        payload: "Название"
    end

    defmodule Closed do
      @moduledoc "Событие без нагрузки."

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: nil

      use Core.Labels.Event, title: "Запись закрыта"
    end
  end
end
