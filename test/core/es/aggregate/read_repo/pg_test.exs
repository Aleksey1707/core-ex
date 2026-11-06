defmodule Core.Es.Aggregate.ReadRepo.PgTest do
  use Core.DataCase, async: true

  use Core.EsAggregateReadRepoContract,
    impl: Core.EsFixture.Account.AtVersion.ReadRepo.Pg,
    repo: Core.EsFixture.Account.Repo.Pg

  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.AtVersion.View

  describe "компиляция" do
    test "repo: — не behaviour event-sourced агрегата" do
      assert_raise CompileError, ~r/должен экспортировать __es_aggregate_repo__\/0/, fn ->
        compile_read_repo!(:state_stored_repo, repo: Core.StateStoredFixture.Repo)
      end
    end

    test "view: — не use Core.View" do
      assert_raise CompileError, ~r/должен экспортировать __view__\/0/, fn ->
        compile_read_repo!(:not_view, view: Account.Repo)
      end
    end

    test "behaviour: — не use Core.Es.Aggregate.ReadRepo" do
      assert_raise CompileError, ~r/должен экспортировать __es_read_repo__\/0/, fn ->
        compile_read_repo_pg!(:not_read_repo, behaviour: Account.Repo)
      end
    end

    test "to_view: — не захват функции арности 1" do
      assert_raise CompileError, ~r/to_view: ожидается захват функции арности 1/, fn ->
        compile_read_repo_pg!(:bad_to_view, to_view: quote(do: &Function.identity/2))
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es\.Aggregate\.ReadRepo: неизвестные опции: \[:views\]$/, fn ->
        compile_read_repo!(:typo, views: View)
      end
    end
  end

  defp compile_read_repo!(name, overrides) do
    opts = Keyword.merge([repo: Account.Repo, view: View], overrides)
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Aggregate.ReadRepo, unquote(opts)
        end
      end
    )
  end

  defp compile_read_repo_pg!(name, overrides) do
    opts =
      Keyword.merge(
        [
          behaviour: Core.EsFixture.Account.AtVersion.ReadRepo,
          to_view: quote(do: &Core.EsFixture.Account.AtVersion.View.from_state/1)
        ],
        overrides
      )

    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Aggregate.ReadRepo.Pg, unquote(opts)
        end
      end
    )
  end
end
