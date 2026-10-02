defmodule Consumer.Infra do
  @moduledoc "Граница-сток: модули без зависимостей на домен — `DAO` и namespace UUIDv5."

  use Boundary,
    deps: [],
    exports: [DAO, StreamID]
end
