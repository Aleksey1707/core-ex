defmodule Core.Es.Personal.Port do
  @moduledoc """
  Фасад порта хранилища ключей субъектов `Core.Es.Personal.KeyStore`: функции `seal/1`, `open/1`,
  `index/1` и `destroy/1` (`@doc false`) — единственный путь библиотеки к порту.

  Реализацию фасад резолвит `Core.Config.key_store/0` на каждом вызове, а telemetry эмитит сам —
  своя реализация порта получает метрики даром. Имена — через `Core.Telemetry.event/1`; меток с
  идентификаторами субъекта, ключа и агрегата нет.

  | Событие | Измерения | Метаданные |
  |---|---|---|
  | `[:es, :personal, :call]` — на каждый вызов порта | `duration` (native) | `op` (`:seal`, `:open`, `:index`, `:destroy`), `result` (`:ok`, `:refused` — `:subject_destroyed`, `:error`) |
  | `[:es, :personal, :open]` — на исход расшифровки пачки | `count` | `outcome` (`:opened`, `:destroyed`, `:unreadable`) |

  `[:es, :personal, :open]` эмитится на каждый исход, встреченный в пачке, — нулевых счётчиков
  нет.
  """

  alias Core.Config
  alias Core.Error
  alias Core.Es.Personal.KeyStore
  alias Core.Result
  alias Core.Telemetry

  # ===== фасад =====

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
