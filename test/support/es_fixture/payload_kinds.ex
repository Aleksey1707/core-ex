defmodule Core.EsFixture.PayloadKinds do
  @moduledoc """
  Нагрузка события, где каждое поле объявлено своим видом спеки и ПДн-местом (`personal: true`)
  с `subject: :aggregate_id`: таблица «вид × уничтоженное значение» (`Core.Es.Personal.Destroyed`).

  Кодек событий не зарегистрирован в фасаде тестов: тест зовёт `Codec.dump/2` и `Codec.load/3`
  напрямую, фасадом для вложенных значений служит `Core.CodecFixture.Internal`.
  """

  defmodule Payload do
    @moduledoc "Каждый вид поля нагрузки — ПДн-место с `subject: :aggregate_id`."

    use Core.Es.Event.Payload,
      fields: [
        prim: [prim: Core.EventFixture.Name, personal: true, subject: :aggregate_id],
        enum: [enum: Core.DerivedFixture.Status, personal: true, subject: :aggregate_id],
        entity: [entity: Core.DerivedFixture.Place, personal: true, subject: :aggregate_id],
        union: [union: Core.DerivedFixture.Mark, personal: true, subject: :aggregate_id],
        list: [list: [prim: Core.EventFixture.Name], personal: true, subject: :aggregate_id],
        set: [set: [prim: Core.EventFixture.Name], personal: true, subject: :aggregate_id],
        map: [
          map: [key: [prim: Core.EventFixture.Name], value: [type: :integer]],
          personal: true,
          subject: :aggregate_id
        ],
        type: [type: :map, personal: true, subject: :aggregate_id]
      ]
  end

  defmodule Event do
    @moduledoc "Семейство события с нагрузкой по каждому виду."

    use Core.Es.Event.Family,
      aggregate: Core.EventFixture,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      codec: Core.EsFixture.PayloadKinds.Codec

    @type t :: struct()
  end

  defmodule Changed do
    @moduledoc "Событие с нагрузкой `Payload`."

    use Core.Es.Event,
      family: Core.EsFixture.PayloadKinds.Event,
      payload: Core.EsFixture.PayloadKinds.Payload
  end

  defmodule Codec do
    @moduledoc "Кодек события `Changed`."

    use Core.Es.Event.Codec,
      family: Core.EsFixture.PayloadKinds.Event,
      type: "payload_kinds_subject",
      tags: %{Core.EsFixture.PayloadKinds.Changed => "payload_kinds_subject.changed"}
  end
end
