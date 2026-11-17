defmodule Core.EsFixture.Itinerary.Errors do
  @moduledoc "Каталог доменных ошибок маршрута."

  alias Core.Error

  require Error

  @doc "Пространство имён ошибок маршрута."
  @spec ns() :: atom()

  def ns, do: :itinerary

  @doc "Доменная ошибка маршрута по коду."
  @spec domain(module(), atom(), term()) :: Error.t()

  def domain(module, :already_exists = code, detail) do
    Error.domain(module, code: code, ns: ns(), message: "Маршрут уже спланирован", detail: detail)
  end

  def domain(module, :version_mismatch = code, detail) do
    Error.domain(module, code: code, ns: ns(), message: "Версия маршрута не совпадает", detail: detail)
  end
end
