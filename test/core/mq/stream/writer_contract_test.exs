defmodule Core.Mq.Stream.WriterContractTest do
  use ExUnit.Case, async: false
  use Core.MqWriterContract, impl: Core.Mq.Stream.Writer

  alias Core.Mq
  alias Core.Mq.Stream

  # Отказ моделируется на `declare_producer`: сообщения контракта идут каждое в свой топик,
  # поэтому номер объявления совпадает с индексом сообщения в пачке.
  defmodule ContractConn do
    @moduledoc false

    def start_link(opts) do
      state = %{declares: 0, fail_at: Keyword.get(opts, :fail_at), sequence: %{}, published: []}

      Agent.start_link(fn -> state end, name: __MODULE__)
    end

    def connect, do: :ok

    def create_stream(_topic), do: :ok

    def declare_producer(topic, _ref) do
      index = Agent.get_and_update(__MODULE__, &{&1.declares, %{&1 | declares: &1.declares + 1}})

      case Agent.get(__MODULE__, & &1.fail_at) do
        nil -> {:ok, topic}
        fail_at when index >= fail_at -> {:error, :access_refused}
        _earlier -> {:ok, topic}
      end
    end

    def publish(producer_id, publishing_id, binary) do
      Agent.update(__MODULE__, fn state ->
        %{
          state
          | sequence: Map.put(state.sequence, producer_id, publishing_id),
            published: state.published ++ [binary]
        }
      end)

      :ok
    end

    def published, do: Agent.get(__MODULE__, & &1.published)

    def producer_sequence(topic, _ref) do
      {:ok, Agent.get(__MODULE__, &Map.get(&1.sequence, topic, 0))}
    end

    def delete_producer(_producer_id), do: :ok
  end

  # ---

  defp ok_writer, do: start_writer(nil)

  defp failing_writer(index), do: start_writer(index)

  defp start_writer(fail_at) do
    start_supervised!(%{
      id: ContractConn,
      start: {ContractConn, :start_link, [[fail_at: fail_at]]}
    })

    start_supervised!(
      {Stream.Writer,
       connection: ContractConn,
       reference_prefix: "contract",
       confirm_timeout_ms: 200,
       confirm_poll_ms: 5}
    )
  end

  defp published(_writer) do
    Enum.map(ContractConn.published(), fn binary ->
      {:ok, message} = Stream.Codec.decode(binary)
      message.body
    end)
  end

  defp message(body) do
    {:ok, message} =
      Mq.Message.new(Mq.Topic.new!("contract_#{body}"), %{}, body, Mq.Key.new!("agg-1"))

    message
  end
end
