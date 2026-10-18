defmodule Core.PersonalBrokenFixture do
  @moduledoc """
  Сломанный агрегат проверок ПДн `Core.Es.EventCompatCase`: персональный Prim во вложенной
  сущности поля без `subject:` (`ContactAdded`) — сборка его не видит — и событие с полем
  `subject:` (`Named`) без уничтоженного варианта; его прежний тег `personal_broken.named.v1` —
  источник апкаста. Фикстуры — `test/support/fixtures/events_broken/personal_broken`.

  `Core.PersonalBrokenFixture.Contact.Codec` и `Core.PersonalBrokenFixture.Event.Codec`
  зарегистрированы в `Core.CodecFixture.plugins/0`.
  """

  defmodule Contact do
    @moduledoc "Контакт — вложенная сущность с персональным Prim."

    @enforce_keys ~w(phone)a
    defstruct @enforce_keys

    @type t :: %__MODULE__{phone: Core.PrimFixture.Personal.t()}
  end

  defmodule Contact.Codec do
    @moduledoc "Плагин контакта по полям."

    use Core.Codec.Plugin,
      fields: [{Core.PersonalBrokenFixture.Contact, phone: [prim: Core.PrimFixture.Personal]}]
  end

  defmodule Event do
    @moduledoc "События сломанного агрегата."

    alias Core.PersonalBrokenFixture.Event.ContactAdded
    alias Core.PersonalBrokenFixture.Event.Named

    @type t :: ContactAdded.t() | Named.t()
  end

  defmodule Event.ContactAdded do
    @moduledoc "Контакт добавлен: ПДн во вложенной сущности поля без `subject:`."

    defmodule Payload do
      @moduledoc "Нагрузка `ContactAdded`."

      use Core.Es.Event.Payload,
        fields: [contact: [entity: Core.PersonalBrokenFixture.Contact]]
    end

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Payload
  end

  defmodule Event.Named do
    @moduledoc "Имя указано: ПДн-поле с `subject: :aggregate_id`."

    defmodule Payload do
      @moduledoc "Нагрузка `Named`."

      use Core.Es.Event.Payload,
        fields: [name: [prim: Core.PrimFixture.Personal, subject: :aggregate_id]]
    end

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: Payload
  end

  defmodule Event.Codec do
    @moduledoc "Кодек событий сломанного агрегата."

    alias Core.Es
    alias Core.PersonalBrokenFixture.Event

    use Es.Event.Codec,
      event: Event,
      type: "personal_broken",
      tags: %{
        Event.ContactAdded => "personal_broken.contact_added",
        Event.Named => "personal_broken.named"
      },
      upcasts: %{"personal_broken.named.v1" => "personal_broken.named"}

    @doc "Нагрузка `personal_broken.named.v1` → нагрузка `personal_broken.named`."
    @spec upcast(String.t(), Es.Event.Codec.wire()) :: wire_payload()

    @impl true
    def upcast("personal_broken.named.v1", envelope),
      do: %{"name" => field(field(envelope, :payload), :title)}
  end
end
