defmodule Core.Es.Event.Codec.Helper do
  @moduledoc """
  Хелперы сборки события из envelope — импортируются `use Core.Es.Event.Codec`.

  Envelope — кортеж `{aggregate_id, version, by, at, id}`, общий для всех событий агрегата.
  """

  alias Core.Es
  alias Core.Version

  @typedoc "Общая часть события: идентификаторы, версия, автор и момент."
  @type envelope :: {struct(), Version.t(), struct(), Es.Event.At.t(), Es.Event.ID.t()}

  @doc "Собрать событие с нагрузкой."
  @spec event(module(), term(), envelope()) :: struct()

  def event(mod, payload, {aggregate_id, version, by, at, id}) when is_atom(mod) do
    mod.new(payload, aggregate_id, version, by, at, id)
  end

  @doc "Собрать событие без нагрузки."
  @spec event(module(), envelope()) :: struct()

  def event(mod, {aggregate_id, version, by, at, id}) when is_atom(mod) do
    mod.new(aggregate_id, version, by, at, id)
  end
end
