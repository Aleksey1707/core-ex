defmodule Core.DerivedFixture do
  @moduledoc """
  События, чьи клаузы нагрузки `Core.Es.Event.Codec` выводит сам: нагрузка-Prim и
  `Core.Es.ValueChanged` с Prim-, nilable- и enum-типом.

  `Core.DerivedFixture.Event.Codec` ручных клауз не объявляет и зарегистрирован в
  `Core.CodecFixture.plugins/0`.
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

  defmodule Event do
    @moduledoc "События с выводимой нагрузкой."

    alias Core.DerivedFixture.Event.NoteChanged
    alias Core.DerivedFixture.Event.Renamed
    alias Core.DerivedFixture.Event.StatusChanged
    alias Core.DerivedFixture.Event.Tagged

    @type t :: Tagged.t() | Renamed.t() | NoteChanged.t() | StatusChanged.t()
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
        Event.StatusChanged => "derived.status_changed"
      }
  end
end
