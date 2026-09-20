defmodule Core.Es.Store.Opts do
  @moduledoc """
  Сверки опций write-builder'ов хранилища событий на компиляции: `use Core.Repo.Pg.StateStored`
  и `use Core.Es.Aggregate.Repo.Pg`.

  Оба builder'а пишут события через `Core.Es.Store.append/5` и собирают его вызов из модулей
  агрегата — кодека событий, outbox и каталога ошибок. Рассинхрон этих модулей ловит компилятор,
  а не первый `append` в рантайме.

  `label` — имя builder'а: по тексту `CompileError` видно, какой `use` его поднял.
  """

  alias Core.Es.Outbox
  alias Core.Helper

  @doc "Кодек событий с `type:` (`use Core.Es.Event.Codec`)."
  @spec event_codec!(module(), String.t()) :: module()

  def event_codec!(event_codec, label) when is_atom(event_codec) and is_binary(label) do
    unless match?({:module, _}, Code.ensure_compiled(event_codec)) and
             function_exported?(event_codec, :__es_type__, 0) do
      raise CompileError,
        description:
          "#{label}: event_codec: #{inspect(event_codec)} — не кодек событий с type: " <>
            "(use Core.Es.Event.Codec)"
    end

    event_codec
  end

  @doc "Prim агрегата у кодека событий (`__es_aggregate_id__/0`) — опция `id:` builder'а."
  @spec ensure_aggregate_id!(module(), module(), String.t()) :: :ok

  def ensure_aggregate_id!(event_codec, id, label)
      when is_atom(event_codec) and is_atom(id) and is_binary(label) do
    aggregate_id = event_codec.__es_aggregate_id__()

    if aggregate_id != id do
      raise CompileError,
        description:
          "#{label}: event_codec: Prim агрегата #{inspect(aggregate_id)} у " <>
            "#{inspect(event_codec)} не равен id: #{inspect(id)}"
    end

    :ok
  end

  @doc """
  Модуль outbox агрегата: `<Aggregate>.Outbox` либо `Core.Es.Outbox.None` при `outbox: :none`.

  `:none` — агрегат не публикует события наружу: сверять с семейством кодека нечего, записей
  outbox нет. Опция остаётся обязательной — отказ от публикации объявляется явно, а не
  пропуском ключа.
  """
  @spec outbox!(keyword(), module(), String.t()) :: module()

  def outbox!(opts, event_codec, label)
      when is_list(opts) and is_atom(event_codec) and is_binary(label) do
    case Keyword.get(opts, :outbox) do
      :none ->
        Outbox.None

      _module ->
        outbox = Helper.Opts.module!(opts, :outbox, label, exports: [from_events: 1, __es_event__: 0])
        ensure_outbox_event!(outbox, event_codec, label)
        outbox
    end
  end

  @doc "Событие outbox (`__es_event__/0`) — семейство кодека событий."
  @spec ensure_outbox_event!(module(), module(), String.t()) :: :ok

  def ensure_outbox_event!(outbox, event_codec, label)
      when is_atom(outbox) and is_atom(event_codec) and is_binary(label) do
    event = outbox.__es_event__()
    family = event_codec.__codec_union__()

    if event != family do
      raise CompileError,
        description:
          "#{label}: outbox: событие #{inspect(event)} у #{inspect(outbox)} " <>
            "не равно семейству кодека #{inspect(family)}"
    end

    :ok
  end

  @doc "Clause `:version_mismatch` в каталоге ошибок — ошибка отказа `Core.Es.Store.append/5`."
  @spec ensure_version_mismatch!(module(), String.t()) :: :ok

  def ensure_version_mismatch!(errors, label) when is_atom(errors) and is_binary(label) do
    errors.domain(__MODULE__, :version_mismatch, nil)
    :ok
  rescue
    FunctionClauseError ->
      reraise CompileError,
              [
                description: "#{label}: errors: отсутствует clause для :version_mismatch в #{inspect(errors)}"
              ],
              __STACKTRACE__
  end
end
