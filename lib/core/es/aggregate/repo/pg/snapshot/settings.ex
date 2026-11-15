defmodule Core.Es.Aggregate.Repo.Pg.Snapshot.Settings do
  @moduledoc """
  Настройка снапшотов write-репозитория event-sourced агрегата (`snapshot:`).

  `nil` вместо структуры — снапшоты выключены; `sealed` — снапшот шифруется под ключом субъекта.
  """

  @enforce_keys [:every, :version, :sealed]
  defstruct @enforce_keys

  @typedoc "Настройка снапшотов: `every` — свёрнутых событий на запись, `version` — часть маркера."
  @type t :: %__MODULE__{every: pos_integer(), version: integer(), sealed: boolean()}
end
