defmodule Core.LabelsBrokenFixture do
  @moduledoc """
  Сломанный набор ратчета полноты подписей (`Core.Labels.CompletenessCase`): событие без названия с
  нагрузкой без решения по полям, Enum без подписей, id без вида, вариант семейства без решения по
  полям, вариант со спекой `fields:`, расходящейся со спекой плагина, и семейство без плагина.
  """

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  defmodule Kind do
    @moduledoc """
    Вид без подписей значений.

    | Значение | Описание |
    |---|---|
    | `:plain` | обычный |
    | `:rare` | редкий |
    """

    use Core.Enum,
      name: "Вид",
      values: ~w(plain rare)a
  end

  defmodule Mark do
    @moduledoc "Метка — семейство вариантов."

    defmodule Bare do
      @moduledoc "Вариант без решения по полям."

      defstruct [:note]
    end

    defmodule Skewed do
      @moduledoc "Вариант: спека `size` расходится со спекой плагина, дискриминатор `kind` — видимое поле."

      defstruct [:size, :color, kind: :skewed]

      use Core.Labels.Fields,
        fields: [
          size: [type: :integer],
          color: [type: :string],
          kind: [text: &Atom.to_string/1]
        ],
        labels: [
          size: "Размер",
          color: "Цвет",
          kind: "Вид"
        ]
    end
  end

  defmodule Mark.Codec do
    @moduledoc "Варианты метки: форма без обёртки, дискриминатор `kind`."

    alias Core.LabelsBrokenFixture.Mark

    use Core.Codec.Plugin,
      union: Mark,
      variants: [
        {Mark.Bare, [kind: :bare], note: [type: :string]},
        {Mark.Skewed, [kind: :skewed], size: [type: :pos_integer], color: [type: :string]}
      ]
  end

  defmodule Loose do
    @moduledoc "Семейство без плагина: его вариантов ратчет не знает."
  end

  defmodule Event do
    @moduledoc false

    @type t :: struct()

    defmodule Unlabelled do
      @moduledoc "Событие без названия: нагрузка без решения по полям."

      defmodule Payload do
        @moduledoc "Нагрузка без подписей."

        use Core.Es.Event.Payload, fields: [note: [type: :string]]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload
    end

    defmodule Marked do
      @moduledoc "Событие с названием и пробелами в нагрузке."

      alias Core.LabelsBrokenFixture

      defmodule Payload do
        @moduledoc "Нагрузка с Enum без подписей, id без вида и семействами."

        use Core.Es.Event.Payload,
          fields: [
            kind: [enum: LabelsBrokenFixture.Kind],
            kinds: [list: [enum: LabelsBrokenFixture.Kind]],
            ref: [prim: Core.LabelsFixture.BareID],
            item: [prim: Core.LabelsFixture.ItemID],
            mark: [union: LabelsBrokenFixture.Mark],
            loose: [union: LabelsBrokenFixture.Loose, optional: true]
          ]

        use Core.Labels.Fields,
          labels: [
            kind: "Вид",
            kinds: "Виды",
            ref: "Ссылка",
            item: "Позиция",
            mark: "Метка",
            loose: "Свободное"
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Метка поставлена"
    end
  end

  defmodule Event.Codec do
    @moduledoc "Кодек сломанного набора."

    alias Core.LabelsBrokenFixture.Event

    @tag_by_mod %{
      Event.Unlabelled => "labels_broken.unlabelled",
      Event.Marked => "labels_broken.marked"
    }

    use Core.Es.Event.Codec,
      event: Event,
      type: "labels_broken",
      tags: @tag_by_mod
  end
end
