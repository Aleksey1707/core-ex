defmodule Core.Mq.DeprecatedTest do
  use ExUnit.Case, async: true

  alias Core.Mq.Dlq.Reader, as: DlqReader
  alias Core.Mq.Kafka.Reader, as: KafkaReader
  alias Core.Mq.Stream.Reader, as: StreamReader

  test "info/1 и metrics/1 читателей помечены @deprecated, а не только в @doc" do
    for {module, fun} <- [{DlqReader, :metrics}, {StreamReader, :info}, {KafkaReader, :info}] do
      assert deprecated?(module, fun, 1), "#{inspect(module)}.#{fun}/1 не помечен @deprecated"
    end
  end

  # ---

  defp deprecated?(module, fun, arity) do
    {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, docs} = Code.fetch_docs(module)

    Enum.any?(docs, fn
      {{:function, ^fun, ^arity}, _anno, _signature, _doc, metadata} ->
        Map.has_key?(metadata, :deprecated)

      _other ->
        false
    end)
  end
end
