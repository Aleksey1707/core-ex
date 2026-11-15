defmodule Core.Es.Store.Write do
  @moduledoc """
  Запись пачки событий агрегата write-builder'ами хранилища событий: `use Core.Es.Aggregate.Repo.Pg`
  и `use Core.Repo.Pg.StateStored`.

  Порядок шагов: операция, сеанс и основание событий (`Core.Es.Operation.stamp/2`) →
  `outbox.from_events` → `Core.Es.Store.append/5` → резервы ключей (`Core.Es.KeyReservation`) →
  шифрование ПДн-значений записей outbox → `Core.Config.outbox_repo().append`. Первый
  `{:error, _}` прерывает конвейер и отдаётся как есть.

  Транзакцию открывает вызывающий: отказ шага оставляет записанным то, что прошло до него, и
  `{:error, _}` MUST выйти из его `Core.Helper.Transact.run/3`, откатывая транзакцию.

  Различия builder'ов — данными `t:Core.Es.Store.Write.Plan.t/0`, а не развилкой:

  - `event_codec` — кодек событий агрегата, его `type:` — тип агрегата потока;
  - `outbox` — `<Aggregate>.Outbox` либо `Core.Es.Outbox.None`;
  - `mismatch` — ошибка отказа записи из `t:Core.Es.Store.mismatch_detail/0`;
  - `continuous?` — непрерывность потока, по умолчанию `false`;
  - `key_reservations` — объявления модулей ключей, по умолчанию `[]`: шаг резервов пропускается;
  - `taken` — ошибка занятого ключа из `code:` модуля ключа и detail `%{scope: scope}`; задаётся
    вместе с непустыми `key_reservations`.
  """

  alias Core.Config
  alias Core.Context
  alias Core.Es

  alias Core.Es.Store.Write.Plan

  @doc "Записать непустую пачку событий агрегата в хранилище событий и outbox; `opts` — опции записи outbox."
  @spec append(Plan.t(), [Es.Event.t(), ...], Context.t(), keyword()) :: Core.Result.unit()

  def append(
        %Plan{event_codec: event_codec, outbox: outbox, mismatch: mismatch} = plan,
        [_ | _] = events,
        %Context{} = context,
        opts
      )
      when is_atom(event_codec) and is_atom(outbox) and is_function(mismatch, 1) and is_list(opts) do
    events = Es.Operation.stamp(events, context)

    with {:ok, records} <- outbox.from_events(events),
         :ok <- Es.Store.append(event_codec, events, context, mismatch, continuous?: plan.continuous?),
         :ok <- reserve(plan, events, context),
         {:ok, records} <- Es.Personal.Wire.seal_records(records) do
      Config.outbox_repo().append(records, context, opts)
    end
  end

  # ---

  defp reserve(%Plan{key_reservations: []}, _events, _context), do: :ok

  defp reserve(%Plan{key_reservations: [_ | _] = declarations, taken: taken}, events, context),
    do: Es.KeyReservation.append(declarations, events, context, taken)
end
