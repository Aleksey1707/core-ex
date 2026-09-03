defmodule Core.Context do
  @moduledoc """
  Сквозной контекст вызова: `%Context{data: map}`.

  Носитель того, что не является аргументом предметной операции: текущий пользователь
  (`Domain.Auth.CurrentUser`), shadow copy (`Repo.Sc`) и подобное. Типизированный
  доступ к ключу — через `Context.Accessor`.

  `get/2` отличает сохранённый `nil` от отсутствующего ключа; `find/2` — нет.
  Последний аргумент публичных usecase/repo-функций — именно `%Context{}`.
  """

  alias Core.Error
  alias Core.Result

  require Error

  defstruct data: %{}

  @type key :: term()
  @type t :: %__MODULE__{data: map()}

  @doc "Создать пустой контекст."
  @spec new() :: t()

  def new, do: %__MODULE__{data: %{}}

  @doc "Создать контекст из map данных."
  @spec new(map()) :: t()

  def new(data) when is_map(data), do: %__MODULE__{data: data}

  @doc "Есть ли ключ в контексте."
  @spec exists?(t(), key()) :: boolean()

  def exists?(%__MODULE__{data: data}, key), do: Map.has_key?(data, key)

  @doc "Найти значение по ключу или `nil`."
  @spec find(t(), key()) :: term() | nil

  def find(%__MODULE__{data: data}, key), do: Map.get(data, key)

  @doc "Получить значение по ключу или `{:error, %Error{}}`."
  @spec get(t(), key()) :: {:ok, term()} | {:error, Error.t()}

  # Через `Map.fetch/2`, а не `find/2`: сохранённый `nil` — это значение, и `exists?/2 == true`
  # обязан означать, что `get/2` вернёт `{:ok, _}`.
  def get(%__MODULE__{data: data}, key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         Error.domain(__MODULE__,
           code: :not_found,
           ns: :context,
           message: "Значение не найдено",
           detail: key
         )}
    end
  end

  @doc "Получить значение по ключу; при отсутствии — `raise Exc`."
  @spec get!(t(), key()) :: term()

  def get!(%__MODULE__{} = context, key), do: Result.unwrap!(get(context, key))

  @doc "Положить значение по ключу."
  @spec put(t(), key(), term()) :: t()

  def put(%__MODULE__{data: data} = context, key, value) do
    %{context | data: Map.put(data, key, value)}
  end

  @doc "Удалить ключ из контекста."
  @spec delete(t(), key()) :: t()

  def delete(%__MODULE__{data: data} = context, key) do
    %{context | data: Map.delete(data, key)}
  end
end
