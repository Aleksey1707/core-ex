defmodule Core.Mq.Kafka.WriterContractTest do
  use ExUnit.Case, async: true
  use Core.MqWriterContract, impl: Core.Mq.Kafka.Writer

  alias Core.Mq

  # Handle klife-writer'а — модуль клиента, поэтому «падать с индекса» держится в словаре
  # процесса теста: `put_many/2` выполняется синхронно в нём же.
  defmodule ContractClient do
    @moduledoc false

    def produce(record) do
      index = Process.get(:contract_index, 0)
      Process.put(:contract_index, index + 1)

      case Process.get(:contract_fail_at) do
        fail_at when is_integer(fail_at) and index >= fail_at ->
          {:error, %{record | error_code: 7}}

        _publishes ->
          Process.put(:contract_published, Process.get(:contract_published, []) ++ [record.value])
          {:ok, record}
      end
    end
  end

  # ---

  defp ok_writer, do: start_client(nil)

  defp failing_writer(index), do: start_client(index)

  defp start_client(fail_at) do
    Process.put(:contract_fail_at, fail_at)
    Process.put(:contract_index, 0)
    Process.put(:contract_published, [])

    ContractClient
  end

  defp published(_writer), do: Process.get(:contract_published, [])

  defp message(body) do
    {:ok, message} =
      Mq.Message.new(Mq.Topic.new!("contract_#{body}"), %{}, body, Mq.Key.new!("agg-1"))

    message
  end
end
