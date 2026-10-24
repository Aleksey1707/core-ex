defmodule Core.Es.Aggregate.RepoTest do
  use ExUnit.Case, async: true

  alias Core.EsFixture.Account

  test "объявляет колбэки get/4, get_decision/5, get_many/3, append/3, refresh/4, page_stream/4" do
    assert Enum.sort(Account.Repo.behaviour_info(:callbacks)) ==
             [append: 3, get: 4, get_decision: 5, get_many: 3, page_stream: 4, refresh: 4]
  end

  test "id агрегата — Prim агрегата его кодека" do
    assert Account.Repo.__es_aggregate_repo__() == %{aggregate: Account, id: Account.ID}
  end

  describe "компиляция" do
    test "требует aggregate" do
      assert_raise CompileError,
                   ~r/^Es\.Aggregate\.Repo: нет обязательных опций: \[:aggregate\]$/,
                   fn -> compile!(NoOpts, []) end
    end

    test "старая форма с id: — неизвестная опция" do
      assert_raise CompileError,
                   ~r/^Es\.Aggregate\.Repo: неизвестные опции: \[:id\]$/,
                   fn -> compile!(OldForm, aggregate: Account, id: Account.ID) end
    end

    test "aggregate — event-sourced агрегат" do
      assert_raise CompileError,
                   ~r/aggregate: модуль .* должен экспортировать __es_event_codec__/,
                   fn -> compile!(StateStored, aggregate: Core.StateStoredFixture.Entity) end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es\.Aggregate\.Repo: неизвестные опции: \[:agregate\]$/, fn ->
        compile!(Typo, [aggregate: Account, agregate: Account], quote(do: raise("тело вычислено")))
      end
    end

    test "атрибут в aggregate: — «ожидается литерал»" do
      message = ~r/^Es\.Aggregate\.Repo: aggregate: ожидается литерал, получено @aggregate$/

      assert_raise CompileError, message, fn ->
        compile!(AttrAggregate, [aggregate: quote(do: @aggregate)], quote(do: @aggregate(Account)))
      end
    end
  end

  # `prelude` стоит в теле перед `use`: тело раскрывается целиком до вычисления, поэтому ошибка
  # раскрытия приходит раньше, чем `raise` в `prelude`.
  defp compile!(name, opts, prelude \\ nil) do
    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          unquote(prelude)
          use Core.Es.Aggregate.Repo, unquote(opts)
        end
      end
    )
  end
end
