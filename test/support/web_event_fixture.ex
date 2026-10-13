defmodule Core.WebEventFixture do
  @moduledoc """
  События страницы событий для тестов `Core.Web.Event`: нагрузка с многословными полями и вложенной
  map'ой, событие без нагрузки. `Core.WebEventFixture.Event.Codec` зарегистрирован в
  `Core.CodecFixture.plugins/0` — иначе фасады не смогли бы дампить события.
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

    @tag_by_mod %{Event.Noted => "web_event.noted", Event.Closed => "web_event.closed"}

    use Core.Es.Event.Codec,
      event: Event,
      type: "web_event",
      tags: @tag_by_mod
  end

  defmodule Plain do
    @moduledoc "Событие страницы событий без ссылки на учётную запись: автор — дамп id."

    use Core.Web.Event, codec: Core.CodecFixture.External
  end

  defmodule WithUser do
    @moduledoc "Событие страницы событий со ссылкой на учётную запись `%{id, login}`."

    use Core.Web.Event,
      codec: Core.CodecFixture.External,
      user_ref: [dump: &Core.WebEventFixture.WithUser.user_ref/2]

    @doc "Ссылка на учётную запись: дамп id и имя."
    @spec user_ref(String.t(), String.t() | nil) :: %{id: String.t(), login: String.t() | nil}

    def user_ref(id, login) when is_binary(id), do: %{id: id, login: login}
  end
end
