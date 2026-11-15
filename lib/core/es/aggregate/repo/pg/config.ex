defmodule Core.Es.Aggregate.Repo.Pg.Config do
  @moduledoc """
  Конфигурация чтения event-sourced агрегата: единственная форма, которую получают движок чтения,
  план, снапшоты и read-репозиторий.

  `use Core.Es.Aggregate.Repo.Pg` собирает базовую структуру на компиляции; вызов конфигурации
  (`__es_read_cfg__/0` и внутренняя `es_aggregate_repo/0`) делает struct update и резолвит `dao`,
  `codec` и источник строк в одной точке — `resolve/4`. В базовой структуре эти три поля — `nil`.

  Все остальные поля обязательны: пропущенная настройка — ошибка сборки репозитория, а не тихий
  `nil`. Правка ключа — `%{@cfg | …}`.
  """

  alias Core.Es.Aggregate.Repo.Pg.Snapshot.Settings

  @enforce_keys [
    :behaviour,
    :aggregate,
    :id,
    :event_codec,
    :type,
    :errors,
    :outbox,
    :snapshot,
    :key_reservations
  ]

  defstruct @enforce_keys ++ [dao: nil, codec: nil, source: nil]

  @typedoc """
  Конфигурация чтения с резолвом зависимостей; `snapshot: nil` — снапшоты выключены.
  """
  @type t :: %__MODULE__{
          behaviour: module(),
          aggregate: module(),
          id: module(),
          event_codec: module(),
          type: String.t(),
          errors: module(),
          outbox: module(),
          snapshot: Settings.t() | nil,
          key_reservations: [module()],
          dao: module(),
          codec: module(),
          source: module()
        }

  @doc """
  Резолв зависимостей конфигурации: `dao`, `codec` и источник строк — при вызове репозитория.

  Единственная точка чтения `Core.Config`: макрос передаёт сюда опции `repo:` / `codec:` или их
  значения по умолчанию.
  """
  @spec resolve(t(), module(), module(), module()) :: t()

  def resolve(%__MODULE__{} = cfg, dao, codec, source) do
    %{cfg | dao: dao, codec: codec, source: source}
  end
end
