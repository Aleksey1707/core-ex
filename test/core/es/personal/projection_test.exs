defmodule Core.Es.Personal.ProjectionTest do
  # Пачка проекции и строка чекпоинта держатся до конца sandbox-транзакции теста, отметка дерева —
  # глобальное состояние ноды.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [open: 0, write!: 3]

  alias Core.Context
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.SubjectID
  alias Core.EsFixture
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  @holder "Иван Петров"

  defmodule Rebuilt do
    @moduledoc false

    # `EsFixture.Projection` новой выкладки: то же имя и read-модель, версия выше.
    use Core.Es.Projection,
      name: "es_fixture",
      events: [Core.EsFixture.Account.Event.HolderSet, Core.Es.Personal.Event.KeyDestroyed],
      version: 2

    @impl true
    defdelegate project(event), to: Core.EsFixture.Projection

    @impl true
    defdelegate clear, to: Core.EsFixture.Projection
  end

  setup do
    on_exit(fn -> :persistent_term.erase(Es.Projection.Supervisor.Mark) end)
  end

  test "destroy_key/3 → run_until_idle: в read-модели нет ПДн субъекта, и после пересборки тоже" do
    id = Account.ID.new()
    other = Account.ID.new()
    write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
    write!(Account.Repo.Pg, other, [open(), set_holder("Пётр Сидоров")])

    assert :ok = Es.Projection.Test.run_until_idle(EsFixture.Projection)
    assert holders() == Enum.sort([{id, @holder}, {other, "Пётр Сидоров"}])

    :ok = Personal.destroy_key(id, UserID.new(), Context.new())

    assert :ok = Es.Projection.Test.run_until_idle(EsFixture.Projection)
    assert holders() == [{other, "Пётр Сидоров"}]

    assert :ok = Es.Projection.Test.run_until_idle(Rebuilt)
    assert holders() == [{other, "Пётр Сидоров"}]
  end

  test "await/3 проекции с событием уничтожения ключа ждёт поток субъекта" do
    id = Account.ID.new()
    write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
    :ok = Personal.destroy_key(id, UserID.new(), Context.new())
    :ignore = Es.Projection.Supervisor.start_link(projections: [EsFixture.Projection], enabled: false, await: :inline)

    assert :ok = EsFixture.Projection.await(Personal, SubjectID.new!(Account.ID.value(id)), 1_000)
    assert holders() == []
  end

  # ---

  defp set_holder(value),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(value), by: UserID.new(), at: Es.Event.At.now!()}

  defp holders do
    EsFixture.Projection.Holder
    |> TestRepo.all()
    |> Enum.map(&{Account.ID.new!(&1.aggregate_id), &1.holder})
    |> Enum.sort()
  end
end
