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
  @spec get(map(), atom()) :: {:ok, term()} | {:error, Error.t()}

  def get(map, key) when is_map(map) and is_atom(key) do
    case find(map, key) do
      nil -> {:error, missing(key)}
      value -> {:ok, value}
    end
  end

  @doc "Обязательное значение по ключу; при отсутствии — `raise Exc`."
  @spec get!(map(), atom()) :: term()

  def get!(map, key) when is_map(map) and is_atom(key), do: Result.unwrap!(get(map, key))

  @doc """
  Разобрать параметры страницы: `limit` / `offset`.

  Опции — `limit_default:` (#{@limit_default}) и `offset_default:` (#{@offset_default}).
  """
  @spec page(map(), keyword()) ::
          {:ok, {Pagination.Limit.t(), Pagination.Offset.t()}} | {:error, Error.t()}

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
  @spec explicit_version(map(), atom()) :: {:ok, Version.t()} | {:error, Error.t()}

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
  @spec expected_version(map(), atom()) :: {:ok, Version.expected()} | {:error, Error.t()}

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
  @spec optional_version(map(), atom()) :: {:ok, Version.expected()} | {:error, Error.t()}

  def optional_version(map, key \\ @if_match_key) when is_map(map) and is_atom(key) do
    case find(map, key) do
      nil -> {:ok, :current}
      value -> parse_version(value)
    end
  end

  # ---

  defp parse_limit(map, opts) do
    map
    |> find(:limit, limit_default(opts))
    |> Pagination.Limit.new()
  end

  defp parse_offset(map, opts) do
    map
    |> find(:offset, offset_default(opts))
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

  defp limit_default(opts), do: Keyword.get(opts, :limit_default, @limit_default)

  defp offset_default(opts), do: Keyword.get(opts, :offset_default, @offset_default)
end
