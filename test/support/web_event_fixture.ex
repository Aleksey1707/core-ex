defmodule Core.WebEventFixture do
  @moduledoc """
  События страницы событий для тестов `Core.Web.Event`: нагрузка с многословными полями и вложенной
  map'ой, нагрузка с ПДн-полями двух субъектов, событие без нагрузки; OpenAPI-схема ссылки на учётную
  запись. `Core.WebEventFixture.Event.Codec` зарегистрирован в `Core.CodecFixture.plugins/0` — иначе
  фасады не смогли бы дампить события.
  """

  defmodule AggID do
    @moduledoc "Идентификатор агрегата."

    use Core.Prim.UUID,
      name: "Идентификатор агрегата",
      version: 7
  end

  defmodule UserID do
    @moduledoc "Идентификатор учётной записи — автора события."

    use Core.Prim.UUID,
      name: "Идентификатор учётной записи",
      version: 7
  end

  defmodule ContactName do
    @moduledoc "Имя контакта — ПДн."

    use Core.Prim.String,
      name: "Имя контакта",
      min_len: 1,
      max_len: 100,
      personal: true
  end

  defmodule Event do
    @moduledoc false

    @type t :: struct()

    defmodule Noted do
      @moduledoc "Событие с нагрузкой: многословные поля и свободная map."

      alias Core.WebEventFixture

      defmodule Payload do
        @moduledoc "Нагрузка `Noted`."

        use Core.Es.Event.Payload,
          fields: [
            first_name: [type: :string],
            extra_data: [type: :map, optional: true]
          ]
      end

      use Core.Es.Event,
        aggregate_id: WebEventFixture.AggID,
        by: WebEventFixture.UserID,
        payload: Payload
    end

    defmodule Contacted do
      @moduledoc "Событие с ПДн-полями: Prim под ключом лица и свободная map'а под ключом агрегата."

      alias Core.WebEventFixture

      defmodule Payload do
        @moduledoc "Нагрузка `Contacted`."

        use Core.Es.Event.Payload,
          fields: [
            person_id: [prim: WebEventFixture.UserID],
            contact_name: [prim: WebEventFixture.ContactName, subject: :person_id],
            home_address: [type: :map, subject: :aggregate_id, optional: true]
          ]
      end

      use Core.Es.Event,
        aggregate_id: WebEventFixture.AggID,
        by: WebEventFixture.UserID,
        payload: Payload
    end

    defmodule Closed do
      @moduledoc "Событие без нагрузки."

      alias Core.WebEventFixture

      use Core.Es.Event,
        aggregate_id: WebEventFixture.AggID,
        by: WebEventFixture.UserID,
        payload: nil
    end
  end

  defmodule Event.Codec do
    @moduledoc "Кодек событий страницы событий (плагин фасадов `Core.CodecFixture.*`)."

    alias Core.WebEventFixture.Event

    @tag_by_mod %{
      Event.Noted => "web_event.noted",
      Event.Contacted => "web_event.contacted",
      Event.Closed => "web_event.closed"
    }

    use Core.Es.Event.Codec,
      event: Event,
      type: "web_event",
      tags: @tag_by_mod
  end

  defmodule UserRef do
    @moduledoc "OpenAPI-схема ссылки на учётную запись `%{id, login}`."

    alias OpenApiSpex.Schema

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "UserRef",
        type: :object,
        properties: %{id: %Schema{type: :string}, login: %Schema{type: :string, nullable: true}},
        required: ~w(id login)a
      },
      struct?: false
    )
  end

  defmodule Plain do
    @moduledoc "Событие страницы событий без ссылки на учётную запись: автор — дамп id."

    use Core.Web.Event, codec: Core.CodecFixture.External
  end

  defmodule WithUser do
    @moduledoc "Событие страницы событий со ссылкой на учётную запись `%{id, login}`."

    use Core.Web.Event,
      codec: Core.CodecFixture.External,
      user_ref: [
        dump: &Core.WebEventFixture.WithUser.user_ref/2,
        schema: Core.WebEventFixture.UserRef
      ]

    @doc "Ссылка на учётную запись: дамп id и имя."
    @spec user_ref(String.t(), String.t() | nil) :: %{id: String.t(), login: String.t() | nil}

    def user_ref(id, login) when is_binary(id), do: %{id: id, login: login}
  end
end
