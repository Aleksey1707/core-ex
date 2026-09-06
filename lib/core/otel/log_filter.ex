defmodule Core.Otel.LogFilter do
  @moduledoc """
  Primary-фильтр `:logger`: `trace_id` / `span_id` активного span'а в metadata записи.

  OTLP-экспорт логов в BEAM не выпущен (`otel_log_handler` живёт в
  `opentelemetry_experimental` без экспортёра), поэтому логи остаются в stdout
  и собираются агентом. Связать их с трейсом можно только идентификаторами
  в самой записи.

  Потребитель регистрирует фильтр один раз при старте:

      :logger.add_primary_filter(:otel_trace, {&Core.Otel.LogFilter.filter/2, []})
      config :logger, metadata: [:trace_id, :span_id]

  Вне span'а (в том числе когда SDK не подключён) запись возвращается нетронутой:
  фильтр ничего не отбрасывает и `:stop` / `:ignore` не возвращает никогда.

  Собственная metadata `opentelemetry_api` (`otel_trace_id`, `otel_span_id`)
  для этого не годится: она обновляется только при смене контекста и остаётся
  в процессе после закрытия span'а, а фильтр читает контекст на момент записи.
  """

  @invalid_trace_id "00000000000000000000000000000000"

  @doc "Добавить `trace_id` / `span_id` в metadata записи лога."
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()

  def filter(event, _extra) do
    put_ids(event, :otel_span.hex_span_ctx(:otel_tracer.current_span_ctx()))
  end

  # ---

  defp put_ids(event, %{otel_trace_id: @invalid_trace_id}), do: event

  defp put_ids(%{meta: meta} = event, %{otel_trace_id: trace_id, otel_span_id: span_id}) do
    %{event | meta: Map.merge(meta, %{trace_id: trace_id, span_id: span_id})}
  end

  defp put_ids(event, %{}), do: event
end
