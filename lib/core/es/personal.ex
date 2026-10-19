defmodule Core.Es.Personal do
  @moduledoc """
  ПДн в событиях под ключом субъекта (ADR-0072…0079): уничтожение ключа субъекта. Термины —
  `CONTEXT.md`, «Персональные данные».

  Порт хранилища ключей `Core.Es.Personal.KeyStore` библиотека зовёт через фасад
  `Core.Es.Personal.Port`: он резолвит реализацию и эмитит telemetry.
  """

  import Core.Guard, only: [is_prim: 1]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal.ActorID
  alias Core.Es.Personal.Event
  alias Core.Es.Personal.Port
  alias Core.Es.Personal.SubjectID
  alias Core.Helper.AfterCommit
  alias Core.Helper.Transact
  alias Core.Prim
  alias Core.Result
  alias Core.Version

  require Error
  require Logger

  @doc """
  Уничтожить ключ субъекта (ADR-0076, ADR-0079): окончательно, повтор — `:ok`.

  `subject_id` — UUID-Prim субъекта (`Prim.UUID` или `Prim.Compose` над ним), `by` — UUID-Prim
  актора: usecase берёт его своим `CurrentUser` до транзакции, как `by` команды. Права проверяет
  usecase; из `%Context{}` библиотека берёт только операцию, сеанс и основание события
  (`Core.Es.Operation`).

  Транзакция — вызывающего, если открыта, иначе своя. В ней:

  1. `destroy` порта хранилища ключей: субъект без ключа получает строку-след;
  2. событие уничтожения ключа `Core.Es.Personal.Event.KeyDestroyed` — версией `1` в поток
     субъекта типа `"core.subject"` через `Core.Es.Store.append`, независимо от ответа порта. Событие
     уже в потоке — отказ записи версии `1` — повтор: `:ok` без записи.

  Ключ уничтожен в момент commit; лог `debug` — после него. Сбой хранилища —
  `{:error, %Core.Error{kind: :app}}` без лога.
  Процессы агрегатов, снапшоты, резервы, read-модель и третьих лиц операция не трогает.
  """
  @spec destroy_key(struct(), struct(), Context.t()) :: Result.unit()

  def destroy_key(subject_id, by, %Context{} = context) when is_prim(subject_id) and is_prim(by) do
    with {:ok, at} <- Es.Event.At.now(),
         {:ok, event} <- key_destroyed(subject_id, by, at),
         do: Transact.run(Config.dao(), fn -> destroy_and_append(subject_id, event, context) end)
  end

  @doc false
  @spec key_destroyed(struct(), struct(), Es.Event.At.t()) :: Result.t(Event.KeyDestroyed.t())

  def key_destroyed(subject_id, by, %Es.Event.At{} = at) when is_prim(subject_id) and is_prim(by) do
    with {:ok, subject} <- SubjectID.new(Prim.unwrap(subject_id)),
         {:ok, actor} <- ActorID.new(Prim.unwrap(by)),
         do: {:ok, Event.KeyDestroyed.new(subject, Version.new(), actor, at)}
  end

  # ---

  # Субъект для порта — дамп его Prim фасадом, как у маркера ПДн-значения кодека событий.
  defp destroy_and_append(subject_id, %Event.KeyDestroyed{} = event, context) do
    with :ok <- Port.destroy(Config.codec().dump(subject_id)) do
      written? =
        case Es.Store.append(Event.Codec, Es.Operation.stamp([event], context), context, &already_written/1) do
          :ok -> true
          {:error, %Error{code: :already_written}} -> false
        end

      AfterCommit.register(fn -> log_destroyed(event, written?) end)
    end
  end

  # Лог — после commit: в транзакции вызывающего ключ уничтожен только с ней.
  defp log_destroyed(%Event.KeyDestroyed{aggregate_id: subject}, written?),
    do: Logger.debug("ключ субъекта уничтожен: subject_id=#{SubjectID.value(subject)} event_written=#{written?}")

  # Поток субъекта — одно событие версии `1`: отказ записи значит, что оно уже в потоке. Ошибка
  # наружу не уходит.
  defp already_written(detail),
    do: Error.app(__MODULE__, code: :already_written, ns: :es, message: "Событие уже записано", detail: detail)
end
