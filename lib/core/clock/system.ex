defmodule Core.Clock.System do
  @moduledoc "Системные часы: реализация `Core.Clock` по умолчанию."

  @behaviour Core.Clock

  @doc "Текущее системное время: UTC `DateTime` с микросекундами."
  @spec now() :: DateTime.t()

  @impl true
  def now, do: DateTime.utc_now(:microsecond)
end
