defmodule Consumer.Account.Errors do
  alias Core.Error

  require Error

  def ns, do: :account

  def domain(module, :not_found = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Счёт не найден", detail: detail)

  def domain(module, :already_exists = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Счёт уже открыт", detail: detail)

  def domain(module, :invalid_status = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Операция недоступна в статусе счёта", detail: detail)

  def domain(module, :version_mismatch = code, detail),
    do: Error.domain(module, code: code, ns: ns(), message: "Версия счёта не совпадает", detail: detail)
end
