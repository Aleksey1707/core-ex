defmodule Core.Es.Aggregate.Test do
  @moduledoc """
  Тестовая поддержка event-sourced агрегата (`Core.Es.Aggregate`): решения `decide/2`
  проверяются без БД.

      import Core.Es.Aggregate.Test, only: [given: 3]

      test "закрыть замороженный счёт — Closed" do
        state = given(%Account{id: id}, [Event.Opened.draft(payload), Event.Frozen.draft()], by: by, at: at)

        assert {:ok, [Event.Closed]} = Account.decide(%Cmd.Close{by: by, at: at}, state)
      end

  Given — результаты `decide/2`, when — `Agg.decide(cmd, state)`, then — результат `decide/2` в
  короткой форме. ExUnit модуль не использует.
  """

  alias Core.Es

  use Core.Options

  @opts_schema [
    by: [type: :any, required: true, doc: "Автор событий — Prim автора из кодека событий агрегата."],
    at: [type: {:struct, Es.Event.At}, required: true, doc: "Время событий."]
  ]
  @doc """
  Состояние после результатов `decide/2` (`Event.Mod.draft(payload)` / `Event.Mod.draft()`).

  События собираются, как в `execute/2`: `id` — новый, `aggregate_id` — `state.id`, версии — по
  порядку от `state.version`, `by` и `at` — из опций. Разные авторы — цепочкой вызовов.

  ## Опции

  #{Core.Options.docs(@opts_schema)}
  """
  @spec given(struct(), [Es.Aggregate.result()], keyword()) :: struct()

  def given(%aggregate{} = state, results, opts) when is_list(results) and is_list(opts) do
    by = Keyword.fetch!(opts, :by)
    at = Keyword.fetch!(opts, :at)

    aggregate.fold(state, Es.Aggregate.events(aggregate, state, results, by, at))
  end
end
