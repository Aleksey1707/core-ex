defmodule Core.Outbox do
  @moduledoc """
  Transactional outbox: примитивы и статусы записи.
  """

  import Core.Helper.String, only: [first_line: 1]

  alias Core.Error

  @typedoc "Фильтр топиков при reserve: все / только / кроме."
  @type topics_filter :: :all | {:only, [String.t()]} | {:except, [String.t()]}

  @doc "Пересекается ли набор топиков с фильтром поллера."
  @spec topics_match?(MapSet.t(String.t()), topics_filter()) :: boolean()

  def topics_match?(%MapSet{} = _topics, :all), do: true

  def topics_match?(%MapSet{} = topics, {:only, listed}) when is_list(listed) do
    Enum.any?(listed, &MapSet.member?(topics, &1))
  end

  def topics_match?(%MapSet{} = topics, {:except, listed}) when is_list(listed) do
    Enum.any?(topics, fn topic -> topic not in listed end)
  end

  @doc """
  Проверить, что фильтры топиков поллеров не пересекаются.

  Порядок доставки держится на одном поллере на топик-группу
  (`14-events-outbox.md`). `FOR UPDATE SKIP LOCKED` защищает от дублей, но не от
  перестановки: два поллера с пересекающимися фильтрами разложат общий топик в брокер
  вперемешку — молча, без единой ошибки. Отказ старта при `DNS_CLUSTER_QUERY` ловит ту же
  ошибку между нодами; эта проверка — внутри одной.

  Звать из `start/2` приложения-потребителя рядом с `check_singleton!/0`, передавая
  конфигурацию `:pollers` как есть.

      Core.Outbox.validate_partition!(
        Application.get_env(:core, Core.Outbox, [])[:pollers] || []
      )

  Раскладка на один поллер (`pollers` не задан) проверки не требует.
  """
  @spec validate_partition!([keyword()]) :: :ok

  def validate_partition!(pollers) when is_list(pollers) do
    pollers
    |> Enum.map(&{Keyword.fetch!(&1, :name), Keyword.fetch!(&1, :topics)})
    |> overlapping_pair()
    |> case do
      nil -> :ok
      {a, b} -> raise ArgumentError, partition_error(a, b)
    end
  end

  @doc """
  Пересекаются ли два фильтра топиков.

  Множество топиков открыто, поэтому два `{:except, _}` пересекаются всегда: их общий
  остаток непуст при любых конечных списках исключений.
  """
  @spec topics_overlap?(topics_filter(), topics_filter()) :: boolean()

  def topics_overlap?(:all, other), do: not empty_filter?(other)

  def topics_overlap?(other, :all), do: not empty_filter?(other)

  def topics_overlap?({:only, a}, {:only, b}), do: Enum.any?(a, &(&1 in b))

  def topics_overlap?({:only, a}, {:except, b}), do: Enum.any?(a, &(&1 not in b))

  def topics_overlap?({:except, b}, {:only, a}), do: Enum.any?(a, &(&1 not in b))

  def topics_overlap?({:except, _}, {:except, _}), do: true

  # ---

  defp overlapping_pair(targets) do
    targets
    |> pairs()
    |> Enum.find(fn {{_, a}, {_, b}} -> topics_overlap?(a, b) end)
  end

  defp pairs([]), do: []

  defp pairs([head | tail]) do
    Enum.map(tail, &{head, &1}) ++ pairs(tail)
  end

  defp empty_filter?({:only, []}), do: true

  defp empty_filter?(_filter), do: false

  defp partition_error({a_name, a_topics}, {b_name, b_topics}) do
    "Core.Outbox: фильтры топиков поллеров пересекаются, порядок доставки не гарантирован: " <>
      "#{inspect(a_name)} #{inspect(a_topics)} и #{inspect(b_name)} #{inspect(b_topics)}. " <>
      "Разведите топики по поллерам через {:only, [...]} без общих элементов " <>
      "(docs/rules/14-events-outbox.md, «Единственность поллера»)"
  end

  defmodule Status do
    @moduledoc """
    Статус записи outbox.

    | Значение | Описание |
    |---|---|
    | `:new` | ждёт публикации; в этом статусе запись создаётся и в него же возвращается при `release` |
    | `:in_work` | зарезервирована поллером под аренду `lease_id`, публикуется прямо сейчас |
    | `:published` | опубликована в брокер; такие записи удаляет `Cleaner` по TTL |
    | `:failed` | исчерпаны попытки публикации; разбирает оператор (`mix outbox.requeue`) |
    """

    use Core.Enum,
      name: first_line(@moduledoc),
      values: ~w(new in_work published failed)a
  end

  defmodule ID do
    @moduledoc """
    Идентификатор записи outbox.
    """

    use Core.Prim.UUID,
      name: first_line(@moduledoc),
      version: 7
  end

  defmodule LeaseID do
    @moduledoc """
    Токен аренды записи outbox.
    """

    use Core.Prim.UUID,
      name: first_line(@moduledoc),
      version: 7
  end

  defmodule Topic do
    @moduledoc """
    Топик (имя stream) сообщения outbox.
    """

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: 100,
      re: ~r/^[a-zA-Z0-9._-]+$/
  end

  defmodule Key do
    @moduledoc """
    Ключ партиционирования сообщения outbox.
    """

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: 200,
      re: ~r/^[a-zA-Z0-9_-]+$/
  end

  defmodule Name do
    @moduledoc """
    Имя (тип) сообщения outbox.
    """

    # Тот же набор символов, что у `Topic`: для событий агрегата имя — это wire-тег
    # (`<Aggregate>.Event.Codec`), а он квалифицирован именем агрегата — `acceptance.created`.
    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: 100,
      re: ~r/^[a-zA-Z0-9._-]+$/
  end

  defmodule Attempts do
    @moduledoc """
    Число попыток публикации.
    """

    use Core.Prim.Integer,
      name: first_line(@moduledoc),
      min: 0

    @doc "Инкремент счётчика попыток."
    @spec inc(t()) :: {:ok, t()} | {:error, Error.t()}

    def inc(%__MODULE__{} = attempts), do: new(value(attempts) + 1)
  end

  defmodule Attempt do
    @moduledoc """
    Номер попытки в истории ошибок.
    """

    use Core.Prim.Integer,
      name: first_line(@moduledoc),
      min: 1
  end

  defmodule ErrorMessage do
    @moduledoc """
    Сообщение об ошибке публикации.
    """

    @max_len 2000

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: @max_len

    @doc "Создать сообщение с обрезкой до #{@max_len} символов."
    @spec create(String.t()) :: {:ok, t()} | {:error, Error.t()}

    def create(raw) when is_binary(raw) do
      trimmed = String.trim(raw)

      text =
        cond do
          trimmed == "" -> "unknown delivery error"
          String.length(trimmed) > @max_len -> String.slice(trimmed, 0, @max_len)
          true -> trimmed
        end

      new(text)
    end
  end

  defmodule CreatedAt do
    @moduledoc """
    Момент создания записи outbox.
    """

    use Core.Prim.DateTime,
      name: first_line(@moduledoc),
      precision: :microsecond
  end

  defmodule UpdatedAt do
    @moduledoc """
    Момент обновления записи outbox.
    """

    use Core.Prim.DateTime,
      name: first_line(@moduledoc),
      precision: :microsecond
  end

  defmodule LockedUntil do
    @moduledoc """
    Срок аренды записи outbox.
    """

    use Core.Prim.DateTime,
      name: first_line(@moduledoc),
      precision: :microsecond
  end

  defmodule PublishedAt do
    @moduledoc """
    Момент публикации записи outbox.
    """

    use Core.Prim.DateTime,
      name: first_line(@moduledoc),
      precision: :microsecond
  end

  defmodule BatchSize do
    @moduledoc """
    Размер пачки для выборки из outbox.
    """

    use Core.Prim.Integer,
      name: first_line(@moduledoc),
      min: 1,
      max: 5000
  end

  defmodule LockDuration do
    @moduledoc """
    Длительность аренды записи outbox (секунды).
    """

    use Core.Prim.Integer,
      name: first_line(@moduledoc),
      min: 1
  end

  defmodule PublishedTTL do
    @moduledoc """
    TTL опубликованных записей outbox (секунды).
    """

    use Core.Prim.Integer,
      name: first_line(@moduledoc),
      min: 1
  end

  defmodule RecordError do
    @moduledoc """
    Элемент истории ошибок публикации.
    """

    @enforce_keys ~w(attempt message)a
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            attempt: Attempt.t(),
            message: ErrorMessage.t()
          }

    @doc "Создать запись об ошибке."
    @spec new(Attempt.t(), ErrorMessage.t()) :: t()

    def new(%Attempt{} = attempt, %ErrorMessage{} = message) do
      %__MODULE__{attempt: attempt, message: message}
    end
  end
end
