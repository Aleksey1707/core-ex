defmodule Core.CodecFixture do
  @moduledoc """
  Codec-профили и entity-фасады для тестов библиотеки.

  Повторяют роль, которую в приложении-потребителе играют `MyApp.Codec.*`:
  Prim-профили задают wire-форматы примитивов, фасады добавляют плагины сущностей.
  Доменных плагинов у библиотеки нет — только `Core.Outbox.Codec`, без которого
  `Outbox.Repo.Pg.Schema` не смог бы писать и читать записи очереди.
  """

  defmodule Prim.Internal do
    @moduledoc "Dump/load Prim для БД / MQ / outbox."

    use Core.Codec,
      uuid: :full,
      datetime: :datetime,
      datetime_tz: "Etc/UTC",
      date: :date,
      decimal: :decimal
  end

  defmodule Prim.External do
    @moduledoc "Dump/load Prim для HTTP JSON."

    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :app,
      date: :iso8601,
      decimal: :string
  end

  @plugins [Core.Outbox.Codec]

  @doc "Плагины entity-фасадов."
  @spec plugins() :: [module()]

  def plugins, do: @plugins
end
