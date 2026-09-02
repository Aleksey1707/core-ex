defmodule Core.Cache.PromEx do
  @moduledoc """
  PromEx plugin: event-метрики обращений к кешам и polling gauge их размера.

  Обязательная опция `sizes:` — MFA-провайдер размеров
  (`[%{cache: String.t(), size: non_neg_integer()}]`), например
  `{MyApp.PromEx.Caches, :sizes, []}`.

  Событие обращения эмитят сами кеширующие фасады (`<ReadRepo>.Cached`)
  через `Core.Cache.Telemetry.emit_request/2`.
  """

  use PromEx.Plugin

  alias Core.PromEx.Safe
  alias Core.Telemetry

  @size_event [:prom_ex, :plugin, :cache, :size]

  @doc false
  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :cache))

    [
      Event.build(
        :cache_event_metrics,
        [
          counter(
            metric_prefix ++ [:requests, :total],
            event_name: request_event(),
            description: "Число обращений к кешу по исходу",
            tags: [:cache, :result],
            tag_values: &request_tag_values/1
          )
        ]
      )
    ]
  end

  @doc false
  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    sizes = Keyword.fetch!(opts, :sizes)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :cache))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      Polling.build(
        :cache_size_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_size_metrics, [sizes]},
        [
          last_value(
            metric_prefix ++ [:size],
            event_name: @size_event,
            description: "Число записей в кеше",
            measurement: :value,
            tags: [:cache],
            tag_values: &cache_tag_values/1
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc false
  @spec execute_size_metrics({module(), atom(), [term()]}) :: :ok

  def execute_size_metrics({mod, fun, args}) when is_atom(mod) and is_atom(fun) do
    Safe.execute("cache sizes", fn ->
      mod
      |> apply(fun, args)
      |> Enum.each(&emit_size/1)
    end)
  end

  # ---

  defp emit_size(%{cache: cache, size: size}) do
    :telemetry.execute(@size_event, %{value: size}, %{cache: cache})
  end

  defp request_tag_values(%{cache: cache, result: result}) do
    %{cache: cache, result: to_string(result)}
  end

  defp cache_tag_values(%{cache: cache}) do
    %{cache: cache}
  end

  # ---
  # Имена событий резолвятся в рантайме: префикс задаёт потребитель
  # (`Core.Config.telemetry_prefix/0`), а библиотека компилируется один раз на все приложения.

  defp request_event, do: Telemetry.event([:cache, :request])
end
