defmodule Core.Es.Store.Write.Plan do
  @moduledoc """
  Данные записи пачки событий для `Core.Es.Store.Write.append/4`.

  Обязательные поля `event_codec`, `outbox`, `mismatch` задают поток и отказ записи. Остальные —
  свойства builder'а: `continuous?` — непрерывность потока, `key_reservations` — объявления модулей
  ключей, `taken` — ошибка занятого ключа. Резервы ключа и ошибка занятого ключа задаются вместе:
  builder ставит оба поля или ни одного, поэтому опечатка в ключе — ошибка сборки, а не тихий
  пропуск резервов.
  """

  alias Core.Error
  alias Core.Es

  @type t :: %__MODULE__{
          event_codec: module(),
          outbox: module(),
          mismatch: (Es.Store.mismatch_detail() -> Error.t()),
          continuous?: boolean(),
          key_reservations: [Es.KeyReservation.declaration()],
          taken: (atom(), map() -> Error.t()) | nil
        }

  @enforce_keys [:event_codec, :outbox, :mismatch]

  defstruct @enforce_keys ++ [continuous?: false, key_reservations: [], taken: nil]
end
