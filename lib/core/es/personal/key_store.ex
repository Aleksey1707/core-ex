defmodule Core.Es.Personal.KeyStore do
  @moduledoc """
  Порт хранилища ключей субъектов (ADR-0075): шифрует, расшифровывает и уничтожает сам — ключ
  субъекта порт не покидает. Термин — `CONTEXT.md`, «Хранилище ключей».

  Реализация резолвится в рантайме — `Core.Config.key_store/0`: по умолчанию встроенная
  `Core.Es.Personal.KeyStore.Pg`, подмена — `config :core, Core.Es.Personal.KeyStore, MyImpl`.
  Свою реализацию проверяет `use Core.Es.Personal.KeyStoreCase, impl: MyImpl`.

  ## Контракт

  - Операции работают пачками; ответ идёт в порядке пачки. Пустая пачка — пустой ответ.
  - Сбой хранилища в любой операции — `{:error, %Core.Error{kind: :app}}` на всю пачку.
  - Идентификатор субъекта — дамп его UUID-Prim (строка); шифротекст и открытый текст — бинари.
    Base64 и обёртку `{"$pd": …}` делает библиотека.
  - AAD-адрес собирает библиотека в однозначной кодировке (`Core.Es.Personal.address/1`);
    заголовок шифротекста реализация добавляет к AAD сама.
  - Шифротекст начинается с версии схемы — пространство реализации: открывает его только
    записавшая реализация.

  | Операция | Вход | Ответ |
  |---|---|---|
  | `seal/1` | `{субъект, адрес, открытый текст}` | шифротексты; уничтоженный субъект — `subject_destroyed/1` на всю пачку |
  | `open/1` | `{шифротекст, адрес}` | `{:ok, открытый текст}`, `:destroyed` или `:unreadable` на элемент |
  | `index/1` | `{область, части ключа}` | строка индекса: детерминирована, различает область и части |
  | `destroy/1` | субъект | `:ok`; повтор — `:ok`, субъект без ключа получает след |

  Ключ субъекта `seal/1` получает или создаёт сам, в транзакции вызывающего, если она открыта.
  После `destroy/1` ни одно значение субъекта не открывается. Ключ, которого хранилище не знает,
  — `:unreadable`, а не `:destroyed`. Реализация мимо транзакции уничтожает необратимо, и ключ-сирота
  после отката ей разрешён.
  """

  alias Core.Error
  alias Core.Result

  require Error

  @typedoc "Идентификатор субъекта — дамп его UUID-Prim."
  @type subject :: String.t()

  @typedoc "Исход расшифровки элемента пачки."
  @type opened :: {:ok, binary()} | :destroyed | :unreadable

  @doc "Зашифровать пачку: `{субъект, адрес, открытый текст}` → шифротекст."
  @callback seal([{subject(), aad :: binary(), plaintext :: binary()}]) :: Result.t([binary()])

  @doc "Расшифровать пачку: `{шифротекст, адрес}` → исход на элемент."
  @callback open([{ciphertext :: binary(), aad :: binary()}]) :: Result.t([opened()])

  @doc "Индекс пачки: `{область, части ключа}` → строка индекса."
  @callback index([{scope :: String.t(), parts :: [String.t()]}]) :: Result.t([String.t()])

  @doc "Уничтожить ключ субъекта: окончательно, повтор — `:ok`."
  @callback destroy(subject()) :: Result.unit()

  @doc """
  Отказ записи ПДн уничтоженного субъекта — доменный, без повтора. Текст константный, в `detail`
  — субъект, без идентификатора ключа. Свою реализацию отказывает этой же ошибкой.
  """
  @spec subject_destroyed(subject()) :: Error.t()

  def subject_destroyed(subject) when is_binary(subject) do
    Error.domain(__MODULE__,
      code: :subject_destroyed,
      ns: :key_store,
      message: "Персональные данные субъекта уничтожены",
      detail: %{subject: subject}
    )
  end
end
