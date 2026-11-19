defmodule Core.LabelsFamilyFixture do
  @moduledoc """
  Семейства ратчета полноты (`Core.Labels.CompletenessCase`):

  - `Mark` — семейство с реестром (`use Core.Union`), плагин которого смешанный: `types:` объявляет
    чужой декларативный тип `Foreign`, а состав семейства обход берёт из реестра;
  - `Legacy` — семейство без реестра с Codec-плагином: состав знает только плагин (`types:`),
    загрузку семейства пишет ручная клауза `load/3`;
  - `Loose` — семейство без реестра и без плагина: состав неизвестен.

  События — по кодеку на семейство событий, чтобы список модулей ратчета включал ровно нужные
  плагины семейств.
  """

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  defmodule Dot do
    @moduledoc "Вариант-структура смешанного семейства."

    use Core.Struct, fields: [size: [type: :pos_integer]]

    use Core.Labels.Fields, labels: [size: "Размер"]
  end

  defmodule Tag do
    @moduledoc "Вариант-Prim смешанного семейства — только id."

    use Core.Prim.UUID,
      name: "Метка",
      version: 7

    use Core.Labels.ID, kind: :id
  end

  defmodule Mark do
    @moduledoc "Семейство с реестром вариантов."

    use Core.Union,
      variants: [
        {Core.LabelsFamilyFixture.Dot, "dot"},
        {Core.LabelsFamilyFixture.Tag, "tag"}
      ]
  end

  defmodule Foreign do
    @moduledoc "Декларативный тип без подписей: чужой `types:` смешанного плагина и вариант другого семейства."

    use Core.Struct, fields: [note: [type: :string]]
  end

  defmodule Other do
    @moduledoc "Семейство с реестром: его вариант — тип, который смешанный плагин объявляет в `types:`."

    use Core.Union, variants: [{Core.LabelsFamilyFixture.Foreign, "foreign"}]
  end

  defmodule Other.Codec do
    @moduledoc "Плагин семейства с реестром; в список модулей ратчета входит без плагина смешанного семейства."

    use Core.Codec.Plugin, union: Core.LabelsFamilyFixture.Other
  end

  defmodule Mark.Codec do
    @moduledoc "Смешанный плагин: реестр семейства и чужой декларативный тип в `types:`."

    use Core.Codec.Plugin,
      types: [Core.LabelsFamilyFixture.Foreign],
      union: Core.LabelsFamilyFixture.Mark
  end

  defmodule Legacy do
    @moduledoc "Семейство без реестра: состав знает только Codec-плагин."
  end

  defmodule Legacy.One do
    @moduledoc "Вариант с решением по полям."

    use Core.Struct, fields: [note: [type: :string]]

    use Core.Labels.Fields, labels: [note: "Примечание"]
  end

  defmodule Legacy.Bare do
    @moduledoc "Вариант без решения по полям: достижим только через плагин семейства без реестра."

    use Core.Struct, fields: [note: [type: :string]]
  end

  defmodule Legacy.Codec do
    @moduledoc "Плагин семейства без реестра: варианты — `types:`, загрузка семейства — ручная клауза."

    alias Core.LabelsFamilyFixture.Legacy

    require Core.Error

    use Core.Codec.Plugin,
      types: [Core.LabelsFamilyFixture.Legacy.One, Core.LabelsFamilyFixture.Legacy.Bare],
      union: Legacy

    def load(Legacy, _data, _codec) do
      {:error, Core.Error.app(code: :unsupported, ns: :codec, message: "семейство без реестра: ручная загрузка")}
    end
  end

  defmodule Loose do
    @moduledoc "Семейство без реестра и без плагина: состав неизвестен."
  end

  defmodule Event do
    @moduledoc false

    defmodule MixedFamily do
      @moduledoc "Семейство событий смешанного плагина."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFamilyFixture,
        aggregate_id: AggID,
        by: ActorID,
        codec: Core.LabelsFamilyFixture.Event.Mixed.Codec

      @type t :: Core.LabelsFamilyFixture.Event.Mixed.t()
    end

    defmodule ForeignFamily do
      @moduledoc "Семейство событий с полем семейства, чей вариант — чужой тип смешанного плагина."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFamilyFixture,
        aggregate_id: AggID,
        by: ActorID,
        codec: Core.LabelsFamilyFixture.Event.Foreign.Codec

      @type t :: Core.LabelsFamilyFixture.Event.Foreign.t()
    end

    defmodule LegacyFamily do
      @moduledoc "Семейство событий семейства без реестра."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFamilyFixture,
        aggregate_id: AggID,
        by: ActorID,
        codec: Core.LabelsFamilyFixture.Event.Legacy.Codec

      @type t :: Core.LabelsFamilyFixture.Event.Legacy.t()
    end

    defmodule LooseFamily do
      @moduledoc "Семейство событий семейства без реестра и плагина."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFamilyFixture,
        aggregate_id: AggID,
        by: ActorID,
        codec: Core.LabelsFamilyFixture.Event.Loose.Codec

      @type t :: Core.LabelsFamilyFixture.Event.Loose.t()
    end

    defmodule Mixed do
      @moduledoc "Событие с видимым полем семейства с реестром."

      defmodule Payload do
        @moduledoc "Нагрузка: поле семейства смешанного плагина."

        use Core.Es.Event.Payload, fields: [mark: [union: Core.LabelsFamilyFixture.Mark, personal: false]]

        use Core.Labels.Fields, labels: [mark: "Метка"]
      end

      use Core.Es.Event,
        family: MixedFamily,
        payload: Payload

      use Core.Labels.Event, title: "Метка поставлена"
    end

    defmodule Foreign do
      @moduledoc "Событие с полем семейства, чей вариант объявлен без подписей."

      defmodule Payload do
        @moduledoc "Нагрузка: поле семейства с вариантом без подписей."

        use Core.Es.Event.Payload, fields: [other: [union: Core.LabelsFamilyFixture.Other, personal: false]]

        use Core.Labels.Fields, labels: [other: "Другое семейство"]
      end

      use Core.Es.Event,
        family: ForeignFamily,
        payload: Payload

      use Core.Labels.Event, title: "Другое семейство указано"
    end

    defmodule Legacy do
      @moduledoc "Событие с полем семейства без реестра."

      defmodule Payload do
        @moduledoc "Нагрузка: поле семейства без реестра."

        use Core.Es.Event.Payload, fields: [legacy: [union: Core.LabelsFamilyFixture.Legacy, personal: false]]

        use Core.Labels.Fields, labels: [legacy: "Семейство без реестра"]
      end

      use Core.Es.Event,
        family: LegacyFamily,
        payload: Payload

      use Core.Labels.Event, title: "Семейство без реестра указано"
    end

    defmodule Loose do
      @moduledoc "Событие с полем семейства без реестра и плагина."

      defmodule Payload do
        @moduledoc "Нагрузка: поле неизвестного семейства."

        use Core.Es.Event.Payload, fields: [loose: [union: Core.LabelsFamilyFixture.Loose, personal: false]]

        use Core.Labels.Fields, labels: [loose: "Неизвестное семейство"]
      end

      use Core.Es.Event,
        family: LooseFamily,
        payload: Payload

      use Core.Labels.Event, title: "Неизвестное семейство указано"
    end
  end

  defmodule Event.Mixed.Codec do
    @moduledoc "Кодек события с полем смешанного семейства."

    use Core.Es.Event.Codec,
      family: Event.MixedFamily,
      type: "labels_family_mixed",
      tags: %{Event.Mixed => "labels_family_mixed.marked"}
  end

  defmodule Event.Foreign.Codec do
    @moduledoc "Кодек события с чужим декларативным типом."

    use Core.Es.Event.Codec,
      family: Event.ForeignFamily,
      type: "labels_family_foreign",
      tags: %{Event.Foreign => "labels_family_foreign.declared"}
  end

  defmodule Event.Legacy.Codec do
    @moduledoc "Кодек события с полем семейства без реестра."

    use Core.Es.Event.Codec,
      family: Event.LegacyFamily,
      type: "labels_family_legacy",
      tags: %{Event.Legacy => "labels_family_legacy.used"}
  end

  defmodule Event.Loose.Codec do
    @moduledoc "Кодек события с полем неизвестного семейства."

    use Core.Es.Event.Codec,
      family: Event.LooseFamily,
      type: "labels_family_loose",
      tags: %{Event.Loose => "labels_family_loose.used"}
  end
end
