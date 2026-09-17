defmodule Consumer.Order.Errors do
  alias Core.Error

  require Error

  def ns, do: :order

  def domain(module, :not_found = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Заказ не найден", detail: detail)

  def domain(module, :already_exists = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Заказ уже оформлен", detail: detail)

  def domain(module, :version_mismatch = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Версия заказа не совпадает", detail: detail)
end
