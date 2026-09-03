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
  Разобрать ожидаемую версию агрегата из заголовка `If-Match`.

  `"*"` → `:current` (`Version.parse/1`); отсутствие заголовка — `:missing_param`.
  """
  @spec version(map(), atom()) :: {:ok, Version.expected()} | {:error, Error.t()}

  def version(map, key \\ @if_match_key) when is_map(map) and is_atom(key) do
    map
    |> get(key)
    |> Result.and_then(&Version.parse/1)
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

  defp missing(key) do
    Error.domain(
      code: :missing_param,
      ns: :web,
      message: "Отсутствует обязательный параметр #{key}",
      detail: key
    )
  end

  defp limit_default(opts), do: Keyword.get(opts, :limit_default, @limit_default)

  defp offset_default(opts), do: Keyword.get(opts, :offset_default, @offset_default)
end
