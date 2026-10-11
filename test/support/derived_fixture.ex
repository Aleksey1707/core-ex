defmodule Core.DerivedFixture do
  @moduledoc """
  События, чьи клаузы нагрузки `Core.Es.Event.Codec` выводит сам: нагрузка-Prim,
  `Core.Es.ValueChanged` с Prim-, nilable- и enum-типом, нагрузка по полям с вариантом
  семейства `Core.DerivedFixture.Mark` (`union:`) и нагрузка-сущность `Core.DerivedFixture.Place`
  со своим плагином.

  `Core.DerivedFixture.Event.Codec` ручных клауз не объявляет; он, `Core.DerivedFixture.Mark.Codec` и
  `Core.DerivedFixture.Place.Codec` зарегистрированы в `Core.CodecFixture.plugins/0`.
  """

  defmodule Note do
    @moduledoc "Заметка — nilable-тип `ValueChanged`."

    use Core.Prim.String,
      name: "Заметка",
      min_len: 1,
      max_len: 200
  end

  defmodule Status do
    @moduledoc """
    Статус — enum-тип `ValueChanged`.

    | Значение | Описание |
    |---|---|
    | `:draft` | черновик |
    | `:active` | действует |
    """

    use Core.Enum, name: "Статус", values: ~w(draft active)a
  end

  defmodule Mark do
    @moduledoc "Метка — семейство вариантов в тегированной форме."

    defmodule Star do
      @moduledoc "Метка: звезда."

      defstruct [:size]
    end

    defmodule Dot do
      @moduledoc "Метка: точка."

      defstruct [:color]
    end
  end

  defmodule Mark.Codec do
    @moduledoc "Варианты метки."

    alias Core.DerivedFixture.Mark

    use Core.Codec.Plugin,
      union: Mark,
      variants: [
        {Mark.Star, "star", size: [type: :pos_integer]},
        {Mark.Dot, "dot", color: [type: :string]}
      ]
  end

  defmodule Place do
    @moduledoc "Место — сущность с ручным плагином, нагрузка события целиком."

    @enforce_keys ~w(name floor)a
    defstruct @enforce_keys
  end

  defmodule Place.Codec do
    @moduledoc "Ручной плагин места: нестандартную wire-форму нагрузки задаёт плагин её типа."

    alias Core.DerivedFixture.Place
    alias Core.EventFixture.Name

    use Core.Codec.Plugin,
      types: [Place]

    @impl true
    def dump(%Place{name: name, floor: floor}, codec), do: %{"name" => codec.dump(name), "level" => floor}

    @impl true
    def load(Place, wire, codec) when is_map(wire) do
      with {:ok, name} <- codec.load(Name, field(wire, :name)),
           do: {:ok, %Place{name: name, floor: field(wire, :level)}}
    end
  end

  defmodule Event do
    @moduledoc "События с выводимой нагрузкой."

    alias Core.DerivedFixture.Event.Located
    alias Core.DerivedFixture.Event.Marked
    alias Core.DerivedFixture.Event.NoteChanged
    alias Core.DerivedFixture.Event.Renamed
    alias Core.DerivedFixture.Event.StatusChanged
    alias Core.DerivedFixture.Event.Tagged

    @type t :: Tagged.t() | Renamed.t() | NoteChanged.t() | StatusChanged.t() | Marked.t() | Located.t()
  end

  defmodule Event.Tagged do
    @moduledoc "Нагрузка — Prim."

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Core.EventFixture.Name
  end

  defmodule Event.Renamed do
    @moduledoc "Нагрузка — `ValueChanged` с Prim-типом."

    defmodule Payload do
      @moduledoc "Старое и новое название."

      use Core.Es.ValueChanged,
        type: Core.EventFixture.Name
    end

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Payload
  end

  defmodule Event.NoteChanged do
    @moduledoc "Нагрузка — `ValueChanged` с `nilable: true`."

    defmodule Payload do
      @moduledoc "Старая и новая заметка; любая из них может отсутствовать."

      use Core.Es.ValueChanged,
        type: Core.DerivedFixture.Note,
        nilable: true
    end

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Payload
  end

  defmodule Event.StatusChanged do
    @moduledoc "Нагрузка — `ValueChanged` с enum-типом."

    defmodule Payload do
      @moduledoc "Старый и новый статус."

      use Core.Es.ValueChanged,
        type: Core.DerivedFixture.Status
    end

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Payload
  end

  defmodule Event.Marked do
    @moduledoc "Нагрузка по полям с вариантом семейства."

    defmodule Payload do
      @moduledoc "Новая метка и прежняя, если была."

      use Core.Es.Event.Payload,
        fields: [
          mark: [union: Core.DerivedFixture.Mark],
          prev: [union: Core.DerivedFixture.Mark, optional: true]
        ]
    end

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Payload
  end

  defmodule Event.Located do
    @moduledoc "Нагрузка — сущность со своим плагином."

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Core.DerivedFixture.Place
  end

  defmodule Event.Codec do
    @moduledoc "Кодек без ручных клауз: нагрузку всех событий он выводит сам."

    alias Core.DerivedFixture.Event

    use Core.Es.Event.Codec,
      event: Event,
      type: "derived",
      tags: %{
        Event.Tagged => "derived.tagged",
        Event.Renamed => "derived.renamed",
        Event.NoteChanged => "derived.note_changed",
        Event.StatusChanged => "derived.status_changed",
        Event.Marked => "derived.marked",
        Event.Located => "derived.located"
      }
  end
end
