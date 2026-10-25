defmodule Core.Web.Params do
  @moduledoc """
  Чтение параметров запроса из map по atom- или одноимённому string-ключу.

  Словарь чтения — `find` / `get` / `get!` (`20-agreements.md`): отсутствие обязательного
  параметра — доменная ошибка `:missing_param`, а не `KeyError`.
  """

  alias Core.Error
  alias Core.Helper
  alias Core.Option
  alias Core.Pagination
  alias Core.Result
  alias Core.Version

  require Error

  use Core.Options

  @if_match_key :"If-Match"
  @limit_default 10
  @offset_default 0

  @doc "Значение по ключу (atom или одноимённая строка); иначе `nil`."
  @spec find(map(), atom()) :: term() | nil

  def find(map, key) when is_map(map) and is_atom(key), do: Helper.Map.field(map, key)

  @doc "Значение по ключу; при отсутствии — `default`."
  @spec find(map(), atom(), term()) :: term()

  def find(map, key, default) when is_map(map) and is_atom(key) do
    map
    |> find(key)
    |> Option.unwrap_or(default)
  end

  @doc "Обязательное значение по ключу; иначе `{:error, %Error{}}`."
  @spec get(map(), atom()) :: Result.t()

  def get(map, key) when is_map(map) and is_atom(key) do
    case find(map, key) do
      nil -> {:error, missing(key)}
      value -> {:ok, value}
    end
  end

  @doc "Обязательное значение по ключу; при отсутствии — `raise Exc`."
  @spec get!(map(), atom()) :: term()

  def get!(map, key) when is_map(map) and is_atom(key), do: Result.unwrap!(get(map, key))

  @doc "Разобрать параметры страницы: `limit` / `offset`."
  @opts_schema [
    limit_default: [type: :pos_integer, default: @limit_default, doc: "`limit`, когда его нет в запросе."],
    offset_default: [type: :non_neg_integer, default: @offset_default, doc: "`offset`, когда его нет в запросе."]
  ]
  @spec page(map(), keyword()) ::
          Result.t({Pagination.Limit.t(), Pagination.Offset.t()})

  def page(map, opts \\ []) when is_map(map) and is_list(opts) do
    with {:ok, limit} <- parse_limit(map, opts),
         {:ok, offset} <- parse_offset(map, opts) do
      {:ok, {limit, offset}}
    end
  end

  @doc """
  Разобрать явную версию агрегата из заголовка `If-Match` — форма команды.

  `"*"` — ошибка `:current_not_allowed`, отсутствие параметра — `:missing_param`.

  `key` — имя параметра в схеме запроса, а не заголовок `conn`: `Plug` отдаёт имена
  заголовков в нижнем регистре, и на `Map.new(conn.req_headers)` дефолт не совпадёт.
  """
  @spec explicit_version(map(), atom()) :: Result.t(Version.t())

  def explicit_version(map, key \\ @if_match_key) when is_map(map) and is_atom(key) do
    case expected_version(map, key) do
      {:ok, %Version{} = version} -> {:ok, version}
      {:ok, :current} -> {:error, current_not_allowed(key)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Разобрать ожидаемую версию агрегата из заголовка `If-Match`: `"*"` → `:current`.

  Отсутствие параметра — `:missing_param`; `key` — как у `explicit_version/2`.
  """
  @spec expected_version(map(), atom()) :: Result.t(Version.expected())

  def expected_version(map, key \\ @if_match_key) when is_map(map) and is_atom(key) do
    case get(map, key) do
      {:ok, value} -> parse_version(value)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Разобрать необязательную версию агрегата из заголовка `If-Match` — форма чтения.

  Отсутствие параметра и `"*"` → `:current`; `key` — как у `explicit_version/2`.
  """
  @spec optional_version(map(), atom()) :: Result.t(Version.expected())

  def optional_version(map, key \\ @if_match_key) when is_map(map) and is_atom(key) do
    case find(map, key) do
      nil -> {:ok, :current}
      value -> parse_version(value)
    end
  end

  # ---

  defp parse_limit(map, opts) do
    map
    |> find(:limit, Keyword.fetch!(opts, :limit_default))
    |> Pagination.Limit.new()
  end

  defp parse_offset(map, opts) do
    map
    |> find(:offset, Keyword.fetch!(opts, :offset_default))
    |> Pagination.Offset.new()
  end

  defp parse_version(value) do
    case Version.parse(value) do
      {:ok, %Version{} = version} -> {:ok, version}
      {:ok, :current} -> {:ok, :current}
      {:error, reason} -> {:error, reason}
    end
  end

  defp missing(key) do
    Error.domain(
      code: :missing_param,
      ns: :web,
      message: "Отсутствует обязательный параметр #{key}",
      detail: key
    )
  end

  defp current_not_allowed(key) do
    Error.domain(
      code: :current_not_allowed,
      ns: :web,
      message: "* недопустим: нужна явная версия",
      detail: key
    )
  end
end
