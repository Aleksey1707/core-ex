defmodule Core.Es.Aggregate.Test do
  @moduledoc """
  Тестовая поддержка event-sourced агрегата (`Core.Es.Aggregate`): решения `decide/2`
  проверяются без БД.

      import Core.Es.Aggregate.Test, only: [given: 3]

      test "закрыть замороженный счёт — Closed" do
        state = given(%Account{id: id}, [{Event.Opened, payload}, Event.Frozen], by: by, at: at)

        assert {:ok, [Event.Closed]} = Account.decide(%Cmd.Close{by: by, at: at}, state)
      end

  Given — результаты `decide/2`, when — `Agg.decide(cmd, state)`, then — результат `decide/2` в
  короткой форме. ExUnit модуль не использует.
  """

  alias Core.Es

  @doc """
  Состояние после результатов `decide/2` (`{Event.Mod, payload}` / `Event.Mod`).

  События собираются, как в `execute/2`: `id` — новый, `aggregate_id` — `state.id`, версии — по
  порядку от `state.version`, `by` и `at` — из опций. `by:` и `at:` обязательны без значений по
  умолчанию (`KeyError`), разные авторы — цепочкой вызовов; неизвестная опция — `ArgumentError`.
  """
  @spec given(struct(), [Es.Aggregate.result()], keyword()) :: struct()

  def given(%aggregate{} = state, results, opts) when is_list(results) and is_list(opts) do
    opts = Keyword.validate!(opts, ~w(by at)a)
    by = Keyword.fetch!(opts, :by)
    at = Keyword.fetch!(opts, :at)

    aggregate.fold(state, Es.Aggregate.events(aggregate, state, results, by, at))
  end
end
