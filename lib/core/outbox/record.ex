defmodule Core.Outbox.Record do
  @moduledoc """
  Запись transactional outbox и операции жизненного цикла.
  """

  import Core.Guard

  alias Core.Error
  alias Core.Option
  alias Core.Outbox
  alias Core.Result

  @enforce_keys ~w(id topic key name payload status attempts errors created_at)a
  defstruct @enforce_keys ++ ~w(locked_until lease_id published_at headers updated_at)a

  @typedoc """
  Тело записи outbox.

  Только JSON-объект: колонка `payload` — `:map`, и list/binary/скаляр не дампятся
  (падение на записи). Продюсер — `Es.Outbox.wire_payload/3` — всегда отдаёт map.
  """
  @type payload :: map()
  @type headers :: %{optional(String.t()) => String.t()}

  @type t :: %__MODULE__{
          id: Outbox.ID.t(),
          topic: Outbox.Topic.t(),
          key: Outbox.Key.t(),
          name: Outbox.Name.t(),
          payload: payload(),
          status: Outbox.Status.t(),
          attempts: Outbox.Attempts.t(),
          locked_until: Outbox.LockedUntil.t() | nil,
          lease_id: Outbox.LeaseID.t() | nil,
          published_at: Outbox.PublishedAt.t() | nil,
          errors: [Outbox.RecordError.t()],
          headers: headers() | nil,
          created_at: Outbox.CreatedAt.t(),
          updated_at: Outbox.UpdatedAt.t() | nil
        }

  @doc """
  Создать новую запись outbox (`status: :new`).

  `headers` — MQ-заголовки записи; delivery отдаёт их как есть и ничего не добавляет от себя.
  `nil` — сообщение публикуется без заголовков.
  """
  @spec new(
          Outbox.Topic.t(),
          Outbox.Key.t(),
          Outbox.Name.t(),
          payload(),
          headers() | nil,
          Outbox.CreatedAt.t() | nil
        ) :: {:ok, t()} | {:error, Error.t()}

  def new(topic, key, name, payload, headers \\ nil, created_at \\ nil)

  def new(
        %Outbox.Topic{} = topic,
        %Outbox.Key{} = key,
        %Outbox.Name{} = name,
        payload,
        headers,
        created_at
      )
      when is_plain_map(payload) and is_opt(created_at, Outbox.CreatedAt) and
             (is_nil(headers) or is_plain_map(headers)) do
    with {:ok, attempts} <- Outbox.Attempts.new(0),
         {:ok, created_at} <-
           created_at
           |> Option.to_result()
           |> Result.or_else(&Outbox.CreatedAt.now/0) do
      {:ok,
       %__MODULE__{
         id: Outbox.ID.new(),
         topic: topic,
         key: key,
         name: name,
         payload: payload,
         status: :new,
         attempts: attempts,
         locked_until: nil,
         lease_id: nil,
         published_at: nil,
         errors: [],
         headers: headers,
         created_at: created_at,
         updated_at: nil
       }}
    end
  end

  @doc """
  Перевести в `:in_work`, увеличить attempts, выставить аренду.

  `lease_id` — токен аренды: результат доставки принимается репозиторием только
  при совпадении токена в строке. Перехват просроченной аренды другим поллером
  меняет токен, и запись результата прежним владельцем становится no-op.
  """
  @spec reserve(t(), Outbox.LockedUntil.t(), Outbox.LeaseID.t(), Outbox.UpdatedAt.t()) ::
          {:ok, t()} | {:error, Error.t()}

  def reserve(
        %__MODULE__{} = record,
        %Outbox.LockedUntil{} = locked_until,
        %Outbox.LeaseID{} = lease_id,
        %Outbox.UpdatedAt{} = at
      ) do
    with {:ok, attempts} <- Outbox.Attempts.inc(record.attempts) do
      {:ok,
       %{
         record
         | status: :in_work,
           attempts: attempts,
           locked_until: locked_until,
           lease_id: lease_id,
           updated_at: at
       }}
    end
  end

  @doc "Отметить запись опубликованной."
  @spec mark_published(t(), Outbox.PublishedAt.t(), Outbox.UpdatedAt.t()) :: t()

  def mark_published(
        %__MODULE__{} = record,
        %Outbox.PublishedAt{} = published_at,
        %Outbox.UpdatedAt{} = at
      ) do
    %{
      record
      | status: :published,
        published_at: published_at,
        locked_until: nil,
        updated_at: at
    }
  end

  @doc """
  Снять аренду без инкремента attempts и без ошибки (хвост батча при fail-stop).

  `status: :new`, `locked_until: nil`.
  """
  @spec release(t(), Outbox.UpdatedAt.t()) :: t()

  def release(%__MODULE__{} = record, %Outbox.UpdatedAt{} = at) do
    %{record | status: :new, locked_until: nil, updated_at: at}
  end

  @doc """
  Зафиксировать ошибку публикации.

  При `attempts >= max_attempts` → `:failed`, иначе → `:new` для retry.
  """
  @spec record_failure(t(), Outbox.ErrorMessage.t(), Outbox.Attempts.t(), Outbox.UpdatedAt.t()) ::
          {:ok, t()} | {:error, Error.t()}

  def record_failure(
        %__MODULE__{} = record,
        %Outbox.ErrorMessage{} = message,
        %Outbox.Attempts{} = max_attempts,
        %Outbox.UpdatedAt{} = at
      ) do
    with {:ok, attempt} <- Outbox.Attempt.new(Outbox.Attempts.value(record.attempts)) do
      error = Outbox.RecordError.new(attempt, message)

      status =
        if Outbox.Attempts.value(record.attempts) >= Outbox.Attempts.value(max_attempts),
          do: :failed,
          else: :new

      {:ok,
       %{
         record
         | errors: record.errors ++ [error],
           locked_until: nil,
           status: status,
           updated_at: at
       }}
    end
  end
end
