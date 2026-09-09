defmodule Core.Mq.Stream.Buffer do
  @moduledoc """
  Буфер записей stream-подписки и учёт кредитов.

  Credit — число in-flight **чанков**: брокер шлёт следующий, только когда за
  потреблённый вернули кредит. Учёт держится на трёх счётчиках сразу (записи текущего
  чанка, сколько их осталось, размеры пришедших следом), поэтому живёт отдельно от
  процесса: здесь его видно и проверяется он без соединения, подписки и GenServer.

  Записи хранятся сырыми — декодирует их `Mq.Stream.Reader` при выдаче.
  """

  defstruct entries: :queue.new(), remaining: 0, next_chunks: :queue.new()

  @type entry :: {non_neg_integer(), binary()}
  @type credits :: non_neg_integer()
  # Поля не раскрываются в типе: `:queue.new/0` даёт dialyzer'у конкретный `{[], []}`,
  # и любой спек с `:queue.queue()` он считает нарушением opaque-типа очереди.
  @opaque t :: %__MODULE__{}

  @doc "Пустой буфер: без записей и без незакрытых чанков."
  @spec new() :: t()

  def new, do: %__MODULE__{}

  @doc """
  Положить записи чанка; вернуть буфер и число кредитов к выдаче.

  Чанк без записей (пустой или отброшенный целиком) кредитуется сразу — потреблять
  в нём нечего, а кредит за него брокер ждёт.
  """
  @spec put_chunk(t(), [entry()]) :: {t(), credits()}

  def put_chunk(%__MODULE__{} = buffer, []), do: {buffer, 1}

  def put_chunk(%__MODULE__{} = buffer, entries) do
    buffer = Enum.reduce(entries, buffer, &put_entry(&2, &1))

    {register_chunk(buffer, length(entries)), 0}
  end

  @doc """
  Взять следующую запись; вернуть буфер и число кредитов к выдаче.

  Кредит возвращается на последней записи чанка: он потреблён целиком.
  """
  @spec take(t()) :: {:ok, entry(), t(), credits()} | {:empty, t()}

  def take(%__MODULE__{} = buffer) do
    case :queue.out(buffer.entries) do
      {:empty, _entries} ->
        {:empty, buffer}

      {{:value, entry}, entries} ->
        {buffer, credits} = consume_slot(%{buffer | entries: entries})

        {:ok, entry, buffer, credits}
    end
  end

  @doc "Число записей в буфере."
  @spec len(t()) :: non_neg_integer()

  def len(%__MODULE__{entries: entries}), do: :queue.len(entries)

  @doc "Сколько записей осталось в текущем чанке."
  @spec remaining(t()) :: non_neg_integer()

  def remaining(%__MODULE__{remaining: remaining}), do: remaining

  # ---

  defp put_entry(%__MODULE__{} = buffer, entry) do
    %{buffer | entries: :queue.in(entry, buffer.entries)}
  end

  defp register_chunk(%__MODULE__{remaining: 0} = buffer, n) do
    %{buffer | remaining: n}
  end

  defp register_chunk(%__MODULE__{} = buffer, n) do
    %{buffer | next_chunks: :queue.in(n, buffer.next_chunks)}
  end

  defp consume_slot(%__MODULE__{remaining: remaining} = buffer) when remaining > 1 do
    {%{buffer | remaining: remaining - 1}, 0}
  end

  defp consume_slot(%__MODULE__{remaining: 1} = buffer) do
    case :queue.out(buffer.next_chunks) do
      {:empty, next_chunks} ->
        {%{buffer | remaining: 0, next_chunks: next_chunks}, 1}

      {{:value, n}, next_chunks} ->
        {%{buffer | remaining: n, next_chunks: next_chunks}, 1}
    end
  end
end
