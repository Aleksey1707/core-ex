defmodule Core.Es.Store.Test do
  @moduledoc """
  Тестовая поддержка хранилища событий (`Core.Es.Store`): записанное читается в тесте
  напрямую, без репозитория агрегата.
  """

  import Ecto.Query

  alias Core.Config
  alias Core.Es
  alias Core.Es.Store.Schema

  @doc """
  Все события потока по возрастанию версии.

  Тип агрегата и семейство событий — из кодека `event_codec`; строки грузятся фасадом
  `Core.Config.codec/0`, апкаст действует. Ошибка загрузки — `Core.Exc`.
  """
  @spec events!(module(), struct()) :: [Es.Event.t()]

  def events!(event_codec, %_{} = aggregate_id) when is_atom(event_codec) do
    codec = Config.codec()
    type = event_codec.__es_type__()
    db_id = codec.dump(aggregate_id)

    from(e in Schema,
      where: e.aggregate_type == ^type and e.aggregate_id == ^db_id,
      order_by: [asc: e.aggregate_version]
    )
    |> Config.dao().all()
    |> Enum.map(&codec.load!(event_codec.__codec_union__(), Schema.to_wire(&1)))
  end
end
