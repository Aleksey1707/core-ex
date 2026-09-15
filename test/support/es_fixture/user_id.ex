defmodule Core.EsFixture.UserID do
  @moduledoc "Идентификатор пользователя — автор событий `Core.EsFixture.Account`."

  use Core.Prim.UUID,
    name: "Идентификатор пользователя",
    version: 7
end
