defmodule Core.Web.Response do
  @moduledoc """
  Обёртка ответа API: `%{status: "ok", data}` / `%{status: "error", data, code, message}`.

  `code` ошибки — строка: `"<ns>/<code>"` доменной `%Error{}` (`error/1`), константа
  `Core.Web.ErrorMapper` (`"internal_error"`, `"not_authorized"`) или имя HTTP-статуса ошибки,
  не дошедшей до контроллера (`Core.Web.ErrorMapper.by_status/2`). Решение — ADR-0062, ADR-0067.

  Обёртка не зависит ни от Plug, ни от Phoenix: это map, который контроллер отдаёт
  своим `json/2`. `page_data/2` — не обёртка, а данные под `success/1`:
  `success(page_data(result, &to_map/1))`.
  """

  alias Core.Error
  alias Core.Pagination

  @typedoc "Успешный ответ."
  @type success :: %{status: String.t(), data: term()}

  @typedoc "Ответ с ошибкой."
  @type error :: %{status: String.t(), data: map(), code: String.t(), message: String.t()}

  @doc "Успешный ответ без данных: `data` — пустой объект."
  @spec success() :: success()

  def success, do: success(%{})

  @doc "Успешный ответ с данными."
  @spec success(term()) :: success()

  def success(data), do: %{status: "ok", data: data}

  @doc """
  Данные страницы — `%{items, total}` через presenter.

  Не обёртка: результат кладётся в `success/1`.
  """
  @spec page_data(Pagination.Result.t(item), (item -> map())) :: %{items: [map()], total: non_neg_integer()}
        when item: var

  def page_data(%Pagination.Result{items: items, total: total}, to_map) when is_function(to_map, 1),
    do: %{items: Enum.map(items, to_map), total: total}

  @doc "Ответ с ошибкой: код, текст для человека и пустой `data`."
  @spec error(atom(), String.t()) :: error()

  def error(code, message), do: error(code, message, %{})

  @doc "Ответ с ошибкой и данными (состав множества ошибок — `%{errors: [...]}`)."
  @spec error(atom(), String.t(), map()) :: error()

  def error(code, message, data) when is_atom(code) and is_binary(message) and is_map(data),
    do: %{status: "error", data: data, code: Atom.to_string(code), message: message}

  @doc """
  Ответ с доменной ошибкой: код — `"<ns>/<code>"`, текст — `message`, состав множества ошибок —
  `data.errors` с тем же правилом кода у каждого элемента.

  Только `kind: :domain`: прикладную ошибку клиенту не показывают (`Core.Web.ErrorMapper`).
  """
  @spec error(Error.t()) :: error()

  def error(%Error{kind: :domain} = error),
    do: %{status: "error", data: data(error), code: code(error), message: to_string(error)}

  # ---

  defp data(%Error{errors: []}), do: %{}

  defp data(%Error{errors: [_ | _] = errors}), do: %{errors: Enum.map(errors, &element/1)}

  defp element(%Error{} = error), do: %{code: code(error), message: to_string(error)}

  defp code(%Error{ns: ns, code: code}), do: "#{ns}/#{code}"
end
