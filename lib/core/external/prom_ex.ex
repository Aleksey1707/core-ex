defmodule Core.External.PromEx do
  @moduledoc """
  PromEx plugin метрик внешних вызовов (`Core.External.call/4`).

  - `external_call_duration_milliseconds{system, operation, outcome}` — гистограмма длительности;
  - `external_call_total{system, operation, outcome}` — число вызовов.

  `outcome`: `ok`, `timeout`, `down`, `rejected` — по классификатору вызывающего, `exception` — по
  исключению в вызове. Рекомендованные алерты `ExternalCallFailing` и `ExternalCallSlow` —
  `21-observability.md`, «Рекомендованные алерты».

  Опции: `metric_prefix:`, `duration_unit:` (по умолчанию `:millisecond`).
  """

  use PromEx.Plugin

  alias Core.Telemetry

  @duration_buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000]

  @doc false
  @spec event_metrics(keyword()) :: [Event.t()]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :external))
    duration_unit = Keyword.get(opts, :duration_unit, :millisecond)
    tags = ~w(system operation outcome)a

    [
      Event.build(
        :external_event_metrics,
        [
          distribution(
            metric_prefix ++ [:call, :duration, PromEx.Utils.make_plural_atom(duration_unit)],
            event_name: call_event(),
            measurement: :duration,
            description: "Длительность внешнего вызова",
            reporter_options: [buckets: @duration_buckets],
            tags: tags,
            tag_values: &call_tag_values/1,
            unit: {:native, duration_unit}
          ),
          counter(
            metric_prefix ++ [:call, :total],
            event_name: call_event(),
            description: "Число внешних вызовов по исходу",
            tags: tags,
            tag_values: &call_tag_values/1
          )
        ]
      )
    ]
  end

  # ---

  defp call_tag_values(%{system: system, operation: operation, outcome: outcome}) do
    %{system: Atom.to_string(system), operation: Atom.to_string(operation), outcome: Atom.to_string(outcome)}
  end

  # Имя события резолвится в рантайме: префикс задаёт потребитель
  # (`Core.Config.telemetry_prefix/0`), а библиотека компилируется один раз на все приложения.
  defp call_event, do: Telemetry.event([:external, :call, :stop])
end
