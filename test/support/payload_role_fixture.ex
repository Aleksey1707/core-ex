defmodule Core.PayloadRoleFixture do
  @moduledoc """
  Нагрузки, роль которых объявляет builder, а не арность конструктора: структура по полям
  с ручным `new/N` в размер декларации — нагрузка-сущность со своим плагином; однополевое
  представление (`Core.View` порождает `new/1`) — не нагрузка по полям; вложенная нагрузка
  узнаётся по роли при сборке кодека.
  """

  defmodule Entity do
    @moduledoc "Структура по полям с ручным `new/N` в размер декларации."

    use Core.Struct,
      fields: [
        name: [prim: Core.EventFixture.Name],
        status: [enum: Core.DerivedFixture.Status, default: :draft]
      ]

    @doc "Ручной конструктор той же арности, что и декларация: роль нагрузки он не меняет."
    @spec new(Core.EventFixture.Name.t(), Core.DerivedFixture.Status.t()) :: t()

    def new(name, status), do: %__MODULE__{name: name, status: status}
  end

  defmodule Entity.Codec do
    @moduledoc "Плагин структуры: wire выводится по её декларации, а не кодеком события."

    use Core.Codec.Plugin, types: [Core.PayloadRoleFixture.Entity]
  end

  defmodule Sealed do
    @moduledoc "Структура по полям с ручным `new/N` и ПДн-местом субъекта агрегата."

    use Core.Struct,
      fields: [
        name: [prim: Core.EventFixture.Name],
        contact: [prim: Core.EventFixture.Contact, subject: :aggregate_id]
      ]

    @doc "Ручной конструктор той же арности, что и декларация."
    @spec new(Core.EventFixture.Name.t(), Core.EventFixture.Contact.t()) :: t()

    def new(name, contact), do: %__MODULE__{name: name, contact: contact}
  end

  defmodule Single do
    @moduledoc "Однополевое представление: `new/1` у View — не признак нагрузки по полям."

    use Core.View, fields: [status: [enum: Core.DerivedFixture.Status]]
  end

  defmodule OpenRole do
    @moduledoc "Роль, прочитанная в теле модуля: собранной интроспекции ещё нет, читается атрибут."

    use Core.Es.Event.Payload, fields: [name: [prim: Core.EventFixture.Name]]

    @open_role Core.Es.Event.Payload.wire_payload?(__MODULE__)

    @doc "Роль нагрузки, прочитанная до сборки модуля."
    @spec open_role() :: boolean()

    def open_role, do: @open_role
  end

  defmodule Event do
    @moduledoc "События с нагрузками, чья роль объявлена builder'ом."

    alias Core.PayloadRoleFixture.Event.NestedPayload
    alias Core.PayloadRoleFixture.Event.StructPayload
    alias Core.PayloadRoleFixture.Event.ViewPayload

    use Core.Es.Event.Family,
      aggregate: Core.DerivedFixture,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      codec: Core.PayloadRoleFixture.Event.Codec

    @type t :: StructPayload.t() | ViewPayload.t() | NestedPayload.t()
  end

  defmodule Event.StructPayload do
    @moduledoc "Нагрузка — структура по полям с ручным `new/2`."

    use Core.Es.Event,
      family: Core.PayloadRoleFixture.Event,
      payload: Core.PayloadRoleFixture.Entity
  end

  defmodule Event.ViewPayload do
    @moduledoc "Нагрузка — однополевое представление."

    use Core.Es.Event,
      family: Core.PayloadRoleFixture.Event,
      payload: Core.PayloadRoleFixture.Single
  end

  defmodule Event.NestedPayload do
    @moduledoc "Нагрузка объявлена вложенно в событие: маркер роли читается при сборке кодека."

    defmodule Payload do
      @moduledoc "Вложенная нагрузка по полям."

      use Core.Es.Event.Payload, fields: [name: [prim: Core.EventFixture.Name]]
    end

    use Core.Es.Event,
      family: Core.PayloadRoleFixture.Event,
      payload: Payload
  end

  defmodule Event.Codec do
    @moduledoc "Кодек событий фикстуры: нагрузку выводит по роли её builder'а."

    alias Core.PayloadRoleFixture.Event

    use Core.Es.Event.Codec,
      family: Event,
      type: "payload_role",
      tags: %{
        Event.StructPayload => "payload_role.struct",
        Event.ViewPayload => "payload_role.view",
        Event.NestedPayload => "payload_role.nested"
      }
  end

  defmodule Codec do
    @moduledoc "Фасад фикстуры: плагин структуры, представление и кодек событий."

    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [
        Core.PayloadRoleFixture.Entity.Codec,
        Core.PayloadRoleFixture.Single.Codec,
        Core.PayloadRoleFixture.Event.Codec
      ]
  end
end
