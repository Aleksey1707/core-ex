defmodule Core.OtelFixture do
  @moduledoc """
  Обвязка тестов трассировки: pid-экспортёр SDK и разбор записи span'а.

  `attach/0` переключает простой процессор на `:otel_exporter_pid` — закрытый span
  приходит текущему процессу сообщением `{:span, запись}`. Экспортёр глобален,
  поэтому тесты, которые его трогают, — `async: false` (`19-testing.md`).
  """

  import Record, only: [defrecordp: 2, extract: 2]

  @span_fields extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  @link_fields extract(:link, from_lib: "opentelemetry/include/otel_span.hrl")
  @status_fields extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")

  defrecordp(:span, @span_fields)
  defrecordp(:link, @link_fields)
  defrecordp(:status, @status_fields)

  @default_timeout_ms 200

  @typedoc "Ссылка span'а: пара идентификаторов связанного span'а."
  @type link :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Разобранная запись экспортированного span'а."
  @type t :: %{
          name: String.t(),
          kind: atom(),
          trace_id: non_neg_integer(),
          span_id: non_neg_integer(),
          parent_span_id: non_neg_integer() | :undefined,
          attributes: %{optional(String.t()) => term()},
          links: [link()],
          status: {atom(), String.t()} | :undefined
        }

  @doc "Направить экспорт закрытых span'ов в текущий процесс."
  @spec attach() :: :ok

  def attach, do: :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

  @doc "Собрать экспортированные span'ы; ожидание — до `timeout` мс на каждый."
  @spec drain(non_neg_integer()) :: [t()]

  def drain(timeout \\ @default_timeout_ms), do: collect(timeout, [])

  @doc "Найти span по имени."
  @spec find([t()], String.t()) :: t() | nil

  def find(spans, name) when is_list(spans) and is_binary(name) do
    Enum.find(spans, &(&1.name == name))
  end

  @doc "Ссылка на span как пара идентификаторов — для сверки с `links`."
  @spec ref(t()) :: link()

  def ref(%{trace_id: trace_id, span_id: span_id}), do: {trace_id, span_id}

  # ---

  defp collect(timeout, acc) do
    receive do
      {:span, record} -> collect(timeout, [to_map(record) | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp to_map(record) do
    %{
      name: span(record, :name),
      kind: span(record, :kind),
      trace_id: span(record, :trace_id),
      span_id: span(record, :span_id),
      parent_span_id: span(record, :parent_span_id),
      attributes: :otel_attributes.map(span(record, :attributes)),
      links: to_links(span(record, :links)),
      status: to_status(span(record, :status))
    }
  end

  defp to_links(links) do
    Enum.map(:otel_links.list(links), &{link(&1, :trace_id), link(&1, :span_id)})
  end

  defp to_status(:undefined), do: :undefined

  defp to_status(record), do: {status(record, :code), status(record, :message)}
end
