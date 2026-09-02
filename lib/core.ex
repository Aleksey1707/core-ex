defmodule Core do
  @moduledoc """
  Shared-фундамент приложения: Prim, Validator, Context, Error/Exc, Codec, Repo, Es,
  Outbox, MQ, PubSub, Pagination, Version, Helper.

  Библиотека абстрактна: она не знает ни имени приложения-потребителя, ни его домена,
  ни web-слоя. Всё, что ей нужно от хоста, приходит одним из трёх путей:

  | Что | Как получает зависимость |
  |---|---|
  | Инфра-синглтоны (`Repo`, Codec-фасад, часовой пояс, ключ шифрования) | `Core.Config` (`config :core, ...`) |
  | OTP-процессы (`Outbox.Poller`, `Outbox.Cleaner`, `Mq.Stream.*`) | `opts` от supervisor'а потребителя |
  | Макросы (`Repo.Pg`, `Prim.DateTime`, `Codec.Facade`) | `use`-опция, fallback → `Core.Config` |

  Контракт конфигурации целиком описан в `Core.Config` и `README.md`.
  """
end
