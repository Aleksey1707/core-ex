defmodule Core.EsFixture.Account.CodecProcess do
  @moduledoc """
  Процесс счёта над репозиторием `Core.EsFixture.Account.CodecRepo`: адрес агрегата в span и
  telemetry — из `codec:` репозитория.
  """

  use Core.Es.Aggregate.Process,
    repo: Core.EsFixture.Account.CodecRepo
end
