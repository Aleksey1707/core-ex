defmodule Core.MqFake do
  @moduledoc """
  Тестовые дублёры MQ: writer, копящий опубликованное, и reliable-reader поверх очереди.

  Заменяют прежний in-memory брокер: он жил в `lib/`, но использовался только тестами
  и расходился с реальным адаптером (`put_many` всегда `:ok`, обход `Mq.Codec`).
  Дублёры держат контракт `Mq.Writer` / `Mq.ReaderReliable` буквально, включая
  stop-on-first-error с индексом.
  """

  defmodule Writer do
    @moduledoc """
    `Mq.Writer`, складывающий сообщения в `Agent` и умеющий падать на заданном индексе.

    `fail_at:` — индекс, начиная с которого публикация возвращает ошибку
    (`put_many` останавливается на нём, как `Stream.Writer`).
    """

    @behaviour Core.Mq.Writer

    alias Core.Error
    alias Core.Mq.Message

    require Error

    defstruct [:agent, :fail_at]

    @type t :: %__MODULE__{agent: pid(), fail_at: non_neg_integer() | nil}

    @doc "Создать writer поверх нового агента."
    @spec new(keyword()) :: t()

    def new(opts \\ []) when is_list(opts) do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      %__MODULE__{agent: agent, fail_at: Keyword.get(opts, :fail_at)}
    end

    @doc "Опубликованные сообщения в порядке публикации."
    @spec published(t()) :: [Message.t()]

    def published(%__MODULE__{agent: agent}), do: Agent.get(agent, &Enum.reverse/1)

    @doc "Тела опубликованных сообщений."
    @spec bodies(t()) :: [binary()]

    def bodies(%__MODULE__{} = writer), do: Enum.map(published(writer), & &1.body)

    @doc false
    @impl true
    def put(%__MODULE__{} = writer, %Message{} = message) do
      case put_many(writer, [message]) do
        :ok -> :ok
        {:error, _index, error} -> {:error, error}
      end
    end

    @doc false
    @impl true
    def put_many(%__MODULE__{} = writer, messages) when is_list(messages) do
      messages
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
        put_one(writer, message, index)
      end)
    end

    # ---

    defp put_one(%__MODULE__{fail_at: index}, _message, index) when is_integer(index) do
      {:halt, {:error, index, publish_error(index)}}
    end

    defp put_one(%__MODULE__{agent: agent}, message, _index) do
      Agent.update(agent, &[message | &1])
      {:cont, :ok}
    end

    defp publish_error(index) do
      Error.app(__MODULE__,
        code: :publish_failed,
        ns: :mq,
        message: "publish failed at #{index}",
        detail: index
      )
    end
  end

  defmodule QueueReader do
    @moduledoc """
    `Mq.ReaderReliable` поверх очереди сообщений, наполняемой тестом.

    До `commit/1` повторно отдаёт то же сообщение — как reliable-чтение из брокера.
    """

    @behaviour Core.Mq.ReaderReliable

    alias Core.Mq.Message

    defstruct [:agent]

    @type t :: %__MODULE__{agent: pid()}

    @doc "Создать reader с начальной очередью."
    @spec new([Message.t()]) :: t()

    def new(messages \\ []) when is_list(messages) do
      {:ok, agent} = Agent.start_link(fn -> messages end)
      %__MODULE__{agent: agent}
    end

    @doc "Добавить сообщение в конец очереди."
    @spec push(t(), Message.t()) :: :ok

    def push(%__MODULE__{agent: agent}, %Message{} = message) do
      Agent.update(agent, &(&1 ++ [message]))
    end

    @doc "Сколько сообщений осталось непрочитанными."
    @spec pending(t()) :: non_neg_integer()

    def pending(%__MODULE__{agent: agent}), do: Agent.get(agent, &length/1)

    @doc false
    @impl true
    def get(%__MODULE__{agent: agent}, _timeout) do
      case Agent.get(agent, & &1) do
        [] -> :empty
        [message | _rest] -> {:ok, message}
      end
    end

    @doc false
    @impl true
    def commit(%__MODULE__{agent: agent}) do
      Agent.update(agent, fn
        [] -> []
        [_committed | rest] -> rest
      end)
    end
  end
end
