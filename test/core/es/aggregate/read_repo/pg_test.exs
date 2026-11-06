defmodule Core.Es.Aggregate.ReadRepo.PgTest do
  use Core.DataCase, async: true

  use Core.EsAggregateReadRepoContract,
    impl: Core.EsFixture.Account.AtVersion.ReadRepo.Pg,
    repo: Core.EsFixture.Account.Repo.Pg

  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.AtVersion.View

  describe "компиляция" do
    test "repo: — state-stored репозиторий: не behaviour event-sourced агрегата" do
      message =
        ~r/^Es\.Aggregate\.ReadRepo: repo: модуль Core\.StateStoredFixture\.Repo должен экспортировать __es_aggregate_repo__\/0 \(use Core\.Es\.Aggregate\.Repo\)$/

      assert_raise CompileError, message, fn ->
        compile_read_repo!(:state_stored_repo, repo: Core.StateStoredFixture.Repo)
      end
    end

    test "view: — не use Core.View" do
      message =
        ~r/^Es\.Aggregate\.ReadRepo: view: модуль Core\.EsFixture\.Account\.Repo должен экспортировать __view__\/0 \(use Core\.View\)$/

      assert_raise CompileError, message, fn ->
        compile_read_repo!(:not_view, view: Account.Repo)
      end
    end

    test "behaviour: — нет маркера: не use Core.Es.Aggregate.ReadRepo" do
      message =
        ~r/^Es\.Aggregate\.ReadRepo\.Pg: behaviour: модуль Core\.EsFixture\.Account\.Repo должен экспортировать __es_read_repo__\/0 \(use Core\.Es\.Aggregate\.ReadRepo\)$/

      assert_raise CompileError, message, fn ->
        compile_read_repo_pg!(:not_read_repo, behaviour: Account.Repo)
      end
    end

    test "behaviour: — неполные колбэки: не use Core.Es.Aggregate.ReadRepo" do
      behaviour = Module.concat(__MODULE__, "GetAtOnlyReadRepo")

      Code.eval_quoted(
        quote do
          defmodule unquote(behaviour) do
            @callback get_at(any(), any(), any()) :: any()

            def __es_read_repo__, do: %{}
          end
        end
      )

      message =
        ~r/^Es\.Aggregate\.ReadRepo\.Pg: behaviour: модуль .*GetAtOnlyReadRepo должен объявлять \[get_at: 4, get_many_at: 2, get_many_at: 3\] \(use Core\.Es\.Aggregate\.ReadRepo\)$/

      assert_raise CompileError, message, fn ->
        compile_read_repo_pg!(:partial_read_repo, behaviour: behaviour)
      end
    end

    test "to_view: — не захват функции арности 1" do
      message = ~r/^Es\.Aggregate\.ReadRepo\.Pg: to_view: ожидается захват функции арности 1/

      assert_raise CompileError, message, fn ->
        compile_read_repo_pg!(:bad_to_view_arity, to_view: quote(do: &Function.identity/2))
      end

      assert_raise CompileError, message, fn ->
        compile_read_repo_pg!(:bad_to_view_literal, to_view: :identity)
      end
    end

    test "to_view: — опция-выражение: атрибут с захватом допустим" do
      assert {{:module, module, _binary, _}, []} =
               compile_read_repo_pg!(
                 :attr_to_view,
                 [to_view: quote(do: @to_view)],
                 quote(do: @to_view(&Core.EsFixture.Account.AtVersion.View.from_state/1))
               )

      assert Core.Helper.Module.exports?(module, :get_at, 3)
    end

    test "repo:/view: — нет обязательных опций" do
      assert_raise CompileError, ~r/^Es\.Aggregate\.ReadRepo: нет обязательных опций: \[:repo\]$/, fn ->
        compile_read_repo!(:no_repo, repo: :__drop__)
      end

      assert_raise CompileError, ~r/^Es\.Aggregate\.ReadRepo: нет обязательных опций: \[:view\]$/, fn ->
        compile_read_repo!(:no_view, view: :__drop__)
      end
    end

    test "repo:/view: — «ожидается литерал»" do
      message = ~r/^Es\.Aggregate\.ReadRepo: repo: ожидается литерал, получено @repo$/

      assert_raise CompileError, message, fn ->
        compile_read_repo!(:attr_repo, [repo: quote(do: @repo)], quote(do: @repo(Account.Repo)))
      end

      message = ~r/^Es\.Aggregate\.ReadRepo: view: ожидается литерал, получено @view$/

      assert_raise CompileError, message, fn ->
        compile_read_repo!(:attr_view, [view: quote(do: @view)], quote(do: @view(View)))
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es\.Aggregate\.ReadRepo: неизвестные опции: \[:views\]$/, fn ->
        compile_read_repo!(:typo, views: View)
      end
    end

    test "недостающие и неизвестные опции — одно сообщение" do
      message =
        ~r/^Es\.Aggregate\.ReadRepo: нет обязательных опций: \[:view\]; неизвестные опции: \[:views\]$/

      assert_raise CompileError, message, fn ->
        compile_read_repo!(:unknown_and_missing, view: :__drop__, views: View)
      end
    end

    test "behaviour:/to_view: — нет обязательных опций" do
      message =
        ~r/^Es\.Aggregate\.ReadRepo\.Pg: нет обязательных опций: \[:behaviour, :to_view\]$/

      assert_raise CompileError, message, fn ->
        compile_read_repo_pg!(:no_opts, behaviour: :__drop__, to_view: :__drop__)
      end
    end

    test "behaviour: — «ожидается литерал»" do
      message = ~r/^Es\.Aggregate\.ReadRepo\.Pg: behaviour: ожидается литерал, получено @behaviour$/

      assert_raise CompileError, message, fn ->
        compile_read_repo_pg!(
          :attr_behaviour,
          [behaviour: quote(do: @behaviour)],
          quote(do: @behaviour(Core.EsFixture.Account.AtVersion.ReadRepo))
        )
      end
    end

    test "неизвестная опция Pg — с меткой" do
      assert_raise CompileError, ~r/^Es\.Aggregate\.ReadRepo\.Pg: неизвестные опции: \[:view\]$/, fn ->
        compile_read_repo_pg!(:unknown_pg, view: View)
      end
    end

    test "недостающие и неизвестные опции Pg — одно сообщение" do
      message =
        ~r/^Es\.Aggregate\.ReadRepo\.Pg: нет обязательных опций: \[:to_view\]; неизвестные опции: \[:to_views\]$/

      assert_raise CompileError, message, fn ->
        compile_read_repo_pg!(:pg_unknown_and_missing, to_view: :__drop__, to_views: :x)
      end
    end
  end

  defp compile_read_repo!(name, overrides, prelude \\ nil) do
    opts =
      [repo: Account.Repo, view: View]
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          unquote(prelude)
          use Core.Es.Aggregate.ReadRepo, unquote(opts)
        end
      end
    )
  end

  defp compile_read_repo_pg!(name, overrides, prelude \\ nil) do
    opts =
      [
        behaviour: Core.EsFixture.Account.AtVersion.ReadRepo,
        to_view: quote(do: &Core.EsFixture.Account.AtVersion.View.from_state/1)
      ]
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          unquote(prelude)
          use Core.Es.Aggregate.ReadRepo.Pg, unquote(opts)
        end
      end
    )
  end
end
