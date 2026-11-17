defmodule Consumer.Domain.Sales.Itinerary.Errors do
  alias Core.Error

  require Error

  def ns, do: :itinerary

  def domain(module, :already_exists = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Маршрут уже спланирован", detail: detail)

  def domain(module, :version_mismatch = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Версия маршрута не совпадает", detail: detail)
end
