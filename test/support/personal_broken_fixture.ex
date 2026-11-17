defmodule Core.PersonalBrokenFixture do
  @moduledoc """
  Сломанный агрегат проверок ПДн `Core.Es.EventCompatCase`: непрозрачная сущность `Leak` без
  общей декларации объявлена `personal: false`, а несёт персональный Prim (`Leaky`) — план такое
  место не видит; событие с ПДн-местом (`Named`) без уничтоженного варианта, его прежний тег
  `personal_broken.named.v1` — источник апкаста. `ContactAdded` — законное вложенное место.
  Фикстуры — `test/support/fixtures/events_broken/personal_broken`.

  `Core.PersonalBrokenFixture.Contact.Codec`, `Core.PersonalBrokenFixture.Leak.Codec` и
  `Core.PersonalBrokenFixture.Event.Codec` зарегистрированы в `Core.CodecFixture.plugins/0`.
  """

  defmodule Contact do
    @moduledoc "Контакт — вложенная сущность с персональным Prim."

    use Core.Struct, fields: [phone: [prim: Core.PrimFixture.Personal]]
  end

  defmodule Contact.Codec do
    @moduledoc "Плагин контакта по полям."

    use Core.Codec.Plugin, types: [Core.PersonalBrokenFixture.Contact]
  end

  defmodule Leak do
    @moduledoc "Непрозрачная сущность без общей декларации: план ПДн её не обходит."

    defstruct [:phone]
  end

  defmodule Leak.Codec do
    @moduledoc "Ручной плагин `Leak`: грузит телефон персональным Prim."

    use Core.Codec.Plugin, types: [Core.PersonalBrokenFixture.Leak]

    @impl true
    def dump(%Core.PersonalBrokenFixture.Leak{phone: phone}, codec), do: %{"phone" => codec.dump(phone)}

    @impl true
    def load(Core.PersonalBrokenFixture.Leak, %{"phone" => phone}, codec) do
      with {:ok, value} <- codec.load(Core.PrimFixture.Personal, phone),
           do: {:ok, %Core.PersonalBrokenFixture.Leak{phone: value}}
    end
  end

  defmodule Event do
    @moduledoc "События сломанного агрегата."

    alias Core.PersonalBrokenFixture.Event.ContactAdded
    alias Core.PersonalBrokenFixture.Event.Leaky
    alias Core.PersonalBrokenFixture.Event.Named

    use Core.Es.Event.Family,
      aggregate: Core.PersonalBrokenFixture,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      codec: Core.PersonalBrokenFixture.Event.Codec

    @type t :: ContactAdded.t() | Leaky.t() | Named.t()
  end

  defmodule Event.ContactAdded do
    @moduledoc "Контакт добавлен: ПДн во вложенной сущности поля без `subject:`."

    defmodule Payload do
      @moduledoc "Нагрузка `ContactAdded`."

      use Core.Es.Event.Payload,
        fields: [contact: [entity: Core.PersonalBrokenFixture.Contact]]
    end

    use Core.Es.Event,
      family: Core.PersonalBrokenFixture.Event,
      payload: Payload
  end

  defmodule Event.Leaky do
    @moduledoc "Утечка: `personal: false` у непрозрачной сущности, внутри — персональный Prim."

    defmodule Payload do
      @moduledoc "Нагрузка `Leaky`."

      use Core.Es.Event.Payload,
        fields: [leak: [entity: Core.PersonalBrokenFixture.Leak, personal: false]]
    end

    use Core.Es.Event,
      family: Core.PersonalBrokenFixture.Event,
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
      family: Core.PersonalBrokenFixture.Event,
      payload: Payload
  end

  defmodule Event.Codec do
    @moduledoc "Кодек событий сломанного агрегата."

    alias Core.Es
    alias Core.PersonalBrokenFixture.Event

    use Es.Event.Codec,
      family: Event,
      type: "personal_broken",
      tags: %{
        Event.ContactAdded => "personal_broken.contact_added",
        Event.Leaky => "personal_broken.leaky",
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
