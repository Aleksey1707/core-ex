defmodule Core.LabelsBrokenFixture do
  @moduledoc """
  Сломанный набор ратчета полноты подписей (`Core.Labels.CompletenessCase`): событие без названия с
  нагрузкой без решения по полям, Enum без подписей, id без вида, вариант семейства без решения по
  полям, вариант со спекой `fields:`, расходящейся со спекой плагина, и семейство без плагина; автор
  без вида id — у событий кодека `Event.Codec`, автор-ссылка на запись и автор только id — по событию
  в своём кодеке.
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

    defmodule Family do
      @moduledoc "Семейство событий кодека `Event.Codec`: объявлено раньше событий, вложенных в `Event`."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsBrokenFixture,
        aggregate_id: AggID,
        by: ActorID,
        codec: Core.LabelsBrokenFixture.Event.Codec

      @type t :: struct()
    end

    defmodule ByRefFamily do
      @moduledoc "Семейство события с автором-ссылкой на запись."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsBrokenFixture,
        aggregate_id: AggID,
        by: Core.LabelsFixture.ItemID,
        codec: Core.LabelsBrokenFixture.Event.ByRef.Codec

      @type t :: struct()
    end

    defmodule ByIDFamily do
      @moduledoc "Семейство события с автором без резолвера."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsBrokenFixture,
        aggregate_id: AggID,
        by: Core.LabelsFixture.SnapshotID,
        codec: Core.LabelsBrokenFixture.Event.ByID.Codec

      @type t :: struct()
    end

    defmodule Unlabelled do
      @moduledoc "Событие без названия: нагрузка без решения по полям."

      defmodule Payload do
        @moduledoc "Нагрузка без подписей."

        use Core.Es.Event.Payload, fields: [note: [type: :string]]
      end

      use Core.Es.Event,
        family: Family,
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
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Метка поставлена"
    end

    defmodule ByRef do
      @moduledoc "Событие от записи: автор — ссылка `kind: :ref`, а не учётная запись."

      use Core.Es.Event,
        family: ByRefFamily,
        payload: nil

      use Core.Labels.Event, title: "Отмечено записью"
    end

    defmodule ByID do
      @moduledoc "Событие от автора `kind: :id`: резолвера нет, имени человеку не называют."

      use Core.Es.Event,
        family: ByIDFamily,
        payload: nil

      use Core.Labels.Event, title: "Отмечено без имени"
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
      event: Event.Family,
      type: "labels_broken",
      tags: @tag_by_mod
  end

  defmodule Event.ByRef.Codec do
    @moduledoc "Кодек события с автором-ссылкой на запись."

    alias Core.LabelsBrokenFixture.Event

    @tag_by_mod %{Event.ByRef => "labels_broken_by_ref.marked"}

    use Core.Es.Event.Codec,
      event: Event.ByRefFamily,
      type: "labels_broken_by_ref",
      tags: @tag_by_mod
  end

  defmodule Event.ByID.Codec do
    @moduledoc "Кодек события с автором без резолвера."

    alias Core.LabelsBrokenFixture.Event

    @tag_by_mod %{Event.ByID => "labels_broken_by_id.marked"}

    use Core.Es.Event.Codec,
      event: Event.ByIDFamily,
      type: "labels_broken_by_id",
      tags: @tag_by_mod
  end
end
