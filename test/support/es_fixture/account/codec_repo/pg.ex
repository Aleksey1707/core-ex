defmodule Core.EsFixture.Account.CodecRepo.Pg do
  @moduledoc """
  Write-репозиторий счёта с фасадом `Core.EsFixture.Account.CodecRepo.Codec`: id счёта дампится
  заглавными буквами вместо `Core.Config.codec/0`.

  Адрес агрегата в span и telemetry процесса обязан совпадать с `codec:` репозитория.
  """

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.CodecRepo,
    errors: Account.Errors,
    outbox: Account.Outbox,
    codec: Core.EsFixture.Account.CodecRepo.Codec
end
