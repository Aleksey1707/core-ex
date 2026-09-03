defmodule Core.Web.Response.Code do
  @moduledoc """
  Числовой код статуса в конверте ответа API

  | Значение | Код | Описание |
  |---|---|---|
  | `:success` | 0 | операция выполнена |
  | `:error` | 1 | отказ, не относящийся к остальным категориям (не найден маршрут, нет прав) |
  | `:domain_error` | 2 | нарушен бизнес-инвариант или невалидный ввод |
  | `:diff_version` | 3 | версия агрегата разошлась с ожидаемой (optimistic lock) |
  | `:auth_error` | 8 | запрос не авторизован |
  | `:critical` | 9 | непредвиденная ошибка на стороне сервера |

  Коды `reserved_codes/0` (`0..9`) зарезервированы за библиотекой: в них добавляются новые
  базовые значения. Свои значения словарь потребителя (`use Core.Web.Response, codes:`)
  нумерует любыми другими целыми — верхней границы нет. Проверяется на компиляции.
  """

  import Core.Helper.String, only: [first_line: 1]

  use Core.Enum,
    name: first_line(@moduledoc),
    codes: %{
      success: 0,
      error: 1,
      domain_error: 2,
      diff_version: 3,
      auth_error: 8,
      critical: 9
    }

  @reserved_codes 0..9

  @doc "Коды, зарезервированные за библиотекой; словарю потребителя они недоступны."
  @spec reserved_codes() :: Range.t()

  def reserved_codes, do: @reserved_codes
end
