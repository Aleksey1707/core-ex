defmodule Blind.Account.Errors do
  alias Core.Error

  require Error

  def domain(module, code, detail)
      when code in ~w(not_found already_exists version_mismatch)a do
    Error.domain(module, code: code, ns: :account, message: "Ошибка счёта", detail: detail)
  end
end
