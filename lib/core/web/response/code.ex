defmodule Core.Web.Response.Code do
  @moduledoc """
  Числовой код статуса в конверте ответа API

  | Значение | Код | Описание |
  |---|---|---|
  | `:success` | 0 | операция выполнена |
  | `:error` | 1 | отказ, не относящийся к остальным категориям (не найден маршрут, нет прав) |
  | `:domain_error` | 2 | нарушен бизнес-инвариант или невалидный ввод |
  | `:diff_version` | 3 | версия агрегата разошлась с ожидаемой (optimistic lock) |
  | `:auth_error` | 254 | запрос не авторизован |
  | `:critical` | 255 | непредвиденная ошибка на стороне сервера |
  """

  import Core.Helper.String, only: [first_line: 1]

  use Core.Enum,
    name: first_line(@moduledoc),
    codes: %{
      success: 0,
      error: 1,
      domain_error: 2,
      diff_version: 3,
      auth_error: 254,
      critical: 255
    }
end
