defmodule Core.EsFixture.Account.CodecRepo do
  @moduledoc """
  Write-behaviour счёта с `codec:`, отличным от `Core.Config.codec/0`.

  Реализация — `Core.EsFixture.Account.CodecRepo.Pg`; нужна тестам адреса агрегата в span и
  telemetry: адрес берётся из конфигурации репозитория, а не из общего фасада.
  """

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account
end
