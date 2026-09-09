defmodule Core.MqFakeContractTest do
  use ExUnit.Case, async: true
  use Core.MqWriterContract, impl: Core.MqFake.Writer

  alias Core.Mq
  alias Core.MqFake

  # ---

  defp ok_writer, do: MqFake.Writer.new()

  defp failing_writer(index), do: MqFake.Writer.new(fail_at: index)

  defp published(writer), do: MqFake.Writer.bodies(writer)

  defp message(body) do
    {:ok, message} =
      Mq.Message.new(Mq.Topic.new!("contract_#{body}"), %{}, body, Mq.Key.new!("agg-1"))

    message
  end
end
