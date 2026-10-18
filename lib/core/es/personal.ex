defmodule Core.Es.Personal do
  @moduledoc """
  ПДн в событиях под ключом субъекта (ADR-0072…0079): фасад библиотеки над портом хранилища ключей
  `Core.Es.Personal.KeyStore`. Термины — `CONTEXT.md`, «Персональные данные».

  Функции порта библиотека зовёт только через фасад: реализацию он резолвит
  `Core.Config.key_store/0` на каждом вызове, а telemetry эмитит сам — своя реализация порта
  получает метрики даром.

  ## Telemetry

  Имена — через `Core.Telemetry.event/1`; меток с идентификаторами субъекта, ключа и агрегата нет.

  | Событие | Измерения | Метаданные |
  |---|---|---|
  | `[:es, :personal, :call]` — на каждый вызов порта | `duration` (native) | `op` (`:seal`, `:open`, `:index`, `:destroy`), `result` (`:ok`, `:refused` — `:subject_destroyed`, `:error`) |
  | `[:es, :personal, :open]` — на исход расшифровки пачки | `count` | `outcome` (`:opened`, `:destroyed`, `:unreadable`) |

  `[:es, :personal, :open]` эмитится на каждый исход, встреченный в пачке, — нулевых счётчиков
  нет.
  """

  import Core.Guard, only: [is_prim: 1]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal.ActorID
  alias Core.Es.Personal.Event
  alias Core.Es.Personal.KeyStore
  alias Core.Es.Personal.SubjectID
  alias Core.Helper.AfterCommit
  alias Core.Helper.Transact
  alias Core.Prim
  alias Core.Result
  alias Core.Telemetry
  alias Core.Version

  require Error
  require Logger

  # ===== уничтожение ключа =====

  @doc """
  Уничтожить ключ субъекта (ADR-0076, ADR-0079): окончательно, повтор — `:ok`.

  `subject_id` — UUID-Prim субъекта (`Prim.UUID` или `Prim.Compose` над ним), `by` — UUID-Prim
  актора: usecase берёт его своим `CurrentUser` до транзакции, как `by` команды. Права проверяет
  usecase, `%Context{}` библиотека не читает.

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
    with {:ok, event} <- key_destroyed(subject_id, by),
         do: Transact.run(Config.dao(), fn -> destroy_and_append(subject_id, event, context) end)
  end

  # ---

  defp key_destroyed(subject_id, by) do
    with {:ok, subject} <- SubjectID.new(Prim.unwrap(subject_id)),
         {:ok, actor} <- ActorID.new(Prim.unwrap(by)),
         {:ok, at} <- Es.Event.At.now(),
         do: {:ok, Event.KeyDestroyed.new(subject, Version.new(), actor, at)}
  end

  # Субъект для порта — дамп его Prim фасадом, как у маркера ПДн-значения кодека событий.
  defp destroy_and_append(subject_id, %Event.KeyDestroyed{} = event, context) do
    with :ok <- destroy(Config.codec().dump(subject_id)) do
      written? =
        case Es.Store.append(Event.Codec, [event], context, &already_written/1) do
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

  # ===== порт =====

  @doc false
  @spec seal([{KeyStore.subject(), binary(), binary()}]) :: Result.t([binary()])

  def seal(items) when is_list(items), do: call(:seal, fn store -> store.seal(items) end)

  @doc false
  @spec open([{binary(), binary()}]) :: Result.t([KeyStore.opened()])

  def open(items) when is_list(items) do
    result = call(:open, fn store -> store.open(items) end)

    with {:ok, outcomes} <- result, do: emit_outcomes(outcomes)

    result
  end

  @doc false
  @spec index([{String.t(), [String.t()]}]) :: Result.t([String.t()])

  def index(items) when is_list(items), do: call(:index, fn store -> store.index(items) end)

  @doc false
  @spec destroy(KeyStore.subject()) :: Result.unit()

  def destroy(subject) when is_binary(subject), do: call(:destroy, fn store -> store.destroy(subject) end)

  # ---

  # Исключение реализации (конфигурация не задана, `raise` своей реализации) — тоже вызов с
  # `result: :error`.
  defp call(op, fun) do
    started = System.monotonic_time()
    result = run(op, started, fun)
    emit_call(op, started, result_label(result))

    result
  end

  defp run(op, started, fun) do
    fun.(Config.key_store())
  rescue
    exception ->
      emit_call(op, started, :error)
      reraise exception, __STACKTRACE__
  end

  defp emit_call(op, started, result) do
    :telemetry.execute(
      Telemetry.event([:es, :personal, :call]),
      %{duration: System.monotonic_time() - started},
      %{op: op, result: result}
    )
  end

  defp result_label(:ok), do: :ok
  defp result_label({:ok, _value}), do: :ok
  defp result_label({:error, %Error{kind: :domain, ns: :key_store, code: :subject_destroyed}}), do: :refused
  defp result_label({:error, _reason}), do: :error

  defp emit_outcomes(outcomes) do
    outcomes
    |> Enum.frequencies_by(&outcome/1)
    |> Enum.each(fn {outcome, count} ->
      :telemetry.execute(Telemetry.event([:es, :personal, :open]), %{count: count}, %{outcome: outcome})
    end)
  end

  defp outcome({:ok, _plaintext}), do: :opened
  defp outcome(:destroyed), do: :destroyed
  defp outcome(:unreadable), do: :unreadable

  # ===== адрес =====

  @doc """
  Адрес для AAD и индекса в однозначной кодировке: каждая часть — длина (32 бита) и байты.

  Перестановка и склейка частей дают другой адрес: `["ab", "c"]` и `["a", "bc"]` различны.
  """
  @spec address([binary()]) :: binary()

  def address(parts) when is_list(parts),
    do: for(part <- parts, into: <<>>, do: <<byte_size(part)::32, part::binary>>)
end
