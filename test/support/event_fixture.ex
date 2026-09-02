defmodule Core.EventFixture do
  @moduledoc """
  Заглушки для макросов event store, которым нужны модули из приложения-потребителя.
  """

  defmodule BySchema do
    @moduledoc "Ecto-схема автора события (`by_schema:` у `Es.Event.Repo.Pg.Schema`)."

    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fake_users" do
      field :login, :string
    end
  end
end
