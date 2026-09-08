defmodule Core.Context do
  @moduledoc """
  Сквозной контекст вызова: `%Context{data: map}`.

  Носитель того, что не является аргументом предметной операции: текущий пользователь
  (`Domain.Auth.CurrentUser`), shadow copy (`Repo.Sc`) и подобное. Типизированный
  доступ к ключу — через `Context.Accessor`.

  Ключ — атом: словарь ключей закрыт кодом (`Context.Accessor`, `Repo.Sc`), а не приходит
  извне.

  `get/2` отличает сохранённый `nil` от отсутствующего ключа; `find/2` — нет.
  Последний аргумент публичных usecase/repo-функций — именно `%Context{}`.

  `inspect/1` печатает только список ключей: контекст лежит в state OTP-процессов
  (`Outbox.Poller`, `Outbox.Cleaner`) и целиком уходит в crash-репорты, а его значения —
  текущий пользователь и прочие чувствительные данные (`12-errors.md`).
  """

  import Core.Guard, only: [is_plain_map: 1]

  alias Core.Error
  alias Core.Result

  require Error

  defstruct data: %{}

  @type key :: atom()
  @type t :: %__MODULE__{data: map()}

  @doc "Создать пустой контекст."
  @spec new() :: t()

  def new, do: %__MODULE__{data: %{}}

  @doc "Создать контекст из map данных (struct — не контекст)."
  @spec new(map()) :: t()

  def new(data) when is_plain_map(data), do: %__MODULE__{data: data}

  @doc "Есть ли ключ в контексте."
  @spec exists?(t(), key()) :: boolean()

  def exists?(%__MODULE__{data: data}, key) when is_atom(key), do: Map.has_key?(data, key)

  @doc "Найти значение по ключу или `nil`."
  @spec find(t(), key()) :: term() | nil

  def find(%__MODULE__{data: data}, key) when is_atom(key), do: Map.get(data, key)

  @doc "Получить значение по ключу или `{:error, %Error{}}`."
  @spec get(t(), key()) :: {:ok, term()} | {:error, Error.t()}

  # Через `Map.fetch/2`, а не `find/2`: сохранённый `nil` — это значение, и `exists?/2 == true`
  # обязан означать, что `get/2` вернёт `{:ok, _}`.
  def get(%__MODULE__{data: data}, key) when is_atom(key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         Error.domain(
           code: :not_found,
           ns: :context,
           message: "Значение не найдено",
           detail: key
         )}
    end
  end

  @doc "Получить значение по ключу; при отсутствии — `raise Exc`."
  @spec get!(t(), key()) :: term()

  def get!(%__MODULE__{} = context, key) when is_atom(key), do: Result.unwrap!(get(context, key))

  @doc "Положить значение по ключу."
  @spec put(t(), key(), term()) :: t()

  def put(%__MODULE__{data: data} = context, key, value) when is_atom(key) do
    %{context | data: Map.put(data, key, value)}
  end

  @doc "Удалить ключ из контекста."
  @spec delete(t(), key()) :: t()

  def delete(%__MODULE__{data: data} = context, key) when is_atom(key) do
    %{context | data: Map.delete(data, key)}
  end
end

defimpl Inspect, for: Core.Context do
  @doc false
  @impl true
  def inspect(%Core.Context{data: data}, opts) do
    keys = Enum.sort(Map.keys(data))

    Inspect.Algebra.concat(["#Context<keys: ", Inspect.Algebra.to_doc(keys, opts), ">"])
  end
end
