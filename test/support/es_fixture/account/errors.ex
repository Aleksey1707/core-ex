defmodule Core.EsFixture.Account.Errors do
  @moduledoc "Каталог доменных ошибок счёта `Core.EsFixture.Account`."

  alias Core.Error

  require Error

  @doc "Пространство имён ошибок счёта."
  @spec ns() :: atom()

  def ns, do: :account

  @doc "Доменная ошибка счёта по коду."
  @spec domain(module(), atom(), term()) :: Error.t()

  def domain(module, :not_found = code, detail) do
    Error.domain(module, code: code, ns: ns(), message: "Счёт не найден", detail: detail)
  end

  def domain(module, :already_exists = code, detail) do
    Error.domain(module, code: code, ns: ns(), message: "Счёт уже открыт", detail: detail)
  end

  def domain(module, :version_mismatch = code, detail) do
    Error.domain(module,
      code: code,
      ns: ns(),
      message: "Версия счёта не совпадает",
      detail: detail
    )
  end

  def domain(module, :name_taken = code, detail) do
    Error.domain(module, code: code, ns: ns(), message: "Название счёта занято", detail: detail)
  end

  def domain(module, :invalid_status = code, detail) do
    Error.domain(module,
      code: code,
      ns: ns(),
      message: "Операция недоступна в статусе счёта",
      detail: detail
    )
  end
end
