defmodule Core.Es.Aggregate.RepoTest do
  use ExUnit.Case, async: true

  alias Core.EsFixture.Account

  test "объявляет колбэки get/4, get_decision/5, get_many/3, append/3, refresh/4, page_stream/4" do
    assert Enum.sort(Account.Repo.behaviour_info(:callbacks)) ==
             [append: 3, get: 4, get_decision: 5, get_many: 3, page_stream: 4, refresh: 4]
  end

  describe "компиляция" do
    test "требует aggregate и id" do
      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo: нет обязательных опций: \[:aggregate, :id\]/,
                   fn -> compile!(NoOpts, []) end
    end

    test "aggregate — event-sourced агрегат" do
      assert_raise CompileError,
                   ~r/aggregate: модуль .* должен экспортировать __es_event_codec__/,
                   fn ->
                     compile!(StateStored,
                       aggregate: Core.StateStoredFixture.Entity,
                       id: Account.ID
                     )
                   end
    end
  end

  defp compile!(name, opts) do
    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Es.Aggregate.Repo, unquote(opts)
        end
      end
    )
  end
end
