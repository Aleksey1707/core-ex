defmodule Core.Cache.Telemetry do
  @moduledoc """
  Telemetry-события обращений к кешам.

  Эмитят кеширующие фасады (`<ReadRepo>.Cached`); метрики собирает `Core.Cache.PromEx`.
  """

  alias Core.Telemetry

  @typedoc "Исход обращения к кешу"
  @type result :: :hit | :miss | :expired | :store_error | :cache_error

  @results ~w(hit miss expired store_error cache_error)a

  @doc "Имя события обращения к кешу."
  @spec request_event() :: [atom()]

  def request_event, do: Telemetry.event([:cache, :request])

  @doc "Возможные исходы обращения к кешу."
  @spec results() :: [result()]

  def results, do: @results

  @doc "Зафиксировать обращение к кешу."
  @spec emit_request(String.t(), result()) :: :ok

  def emit_request(cache, result) when is_binary(cache) and result in @results do
    :telemetry.execute(request_event(), %{count: 1}, %{cache: cache, result: result})
  end
end
