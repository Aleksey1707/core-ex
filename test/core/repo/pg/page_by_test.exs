defmodule Core.Repo.Pg.PageByTest do
  use Core.DataCase, async: true

  alias Core.Config
  alias Core.Context
  alias Core.Es
  alias Core.EventFixture.AggID
  alias Core.Pagination
  alias Core.StateStoredFixture
  alias Core.StateStoredFixture.Entity
  alias Core.Version

  require Config

  @repo Config.repo!(StateStoredFixture.Repo)

  defmodule ReadRepo do
    @moduledoc false

    use Core.Repo, only: ~w(page)a
  end

  defmodule ReadRepo.Pg do
    @moduledoc false

    import Ecto.Query, only: [dynamic: 2, from: 2]

    use Core.Repo.Pg,
      behaviour: Core.Repo.Pg.PageByTest.ReadRepo,
      schema: Core.StateStoredFixture.Schema,
      query: from(e in Core.StateStoredFixture.Schema, order_by: e.name),
      to_entity: &Function.identity/1,
      default_filters: &Core.Repo.Pg.PageByTest.ReadRepo.Pg.visible/1,
      errors: Core.EventFixture.Errors

    def visible(_context), do: dynamic([e], e.name != "Альфа-скрытая")

    def page_by_prefix(prefix, limit, offset, context),
      do: Repo.Pg.page_by(@pg, dynamic([e], like(e.name, ^"#{prefix}%")), limit, offset, context)
  end

  setup do
    for name <- ~w(Альфа-1 Альфа-2 Альфа-3 Альфа-скрытая Бета-1) do
      assert {:ok, _} = @repo.insert(entity(name), Context.new())
    end

    :ok
  end

  test "страница по фильтру в scope default_filters; total — по тому же фильтру и scope" do
    assert %Pagination.Result{items: items, total: 3} = page("Альфа", 2, 1)

    assert Enum.map(items, & &1.name) == ~w(Альфа-2 Альфа-3)
  end

  test "страница за концом выборки пуста, total по фильтру сохраняется" do
    assert %Pagination.Result{items: [], total: 3} = page("Альфа", 10, 3)
  end

  test "фильтр без совпадений — пустая страница с total: 0" do
    assert %Pagination.Result{items: [], total: 0} = page("Гамма", 10, 0)
  end

  defp page(prefix, limit, offset),
    do: ReadRepo.Pg.page_by_prefix(prefix, Pagination.Limit.new!(limit), Pagination.Offset.new!(offset), Context.new())

  defp entity(name) do
    %Entity{
      id: AggID.new(),
      version: Version.new!(1),
      name: name,
      children: %{},
      events: Es.Events.new()
    }
  end
end
