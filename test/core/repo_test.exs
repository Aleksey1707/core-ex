defmodule Core.RepoTest do
  use ExUnit.Case, async: true

  alias Core.Prim
  alias Core.Repo

  defmodule SampleView do
    @moduledoc false
    defstruct [:id, :name]

    @type t :: %__MODULE__{id: String.t(), name: String.t()}
  end

  defmodule SampleEntity do
    @moduledoc false
    defstruct [:id]

    @type t :: %__MODULE__{id: String.t()}
  end

  defmodule SampleID do
    use Prim.UUID, name: "ID", version: 4
  end

  test "expand_only expands presets" do
    assert :get in Repo.expand_only(:full)
    assert :page in Repo.expand_only(:full)
    assert :find_many in Repo.expand_only(:full)
    assert :get_many in Repo.expand_only(:full)
    assert :exists_all? in Repo.expand_only(:full)
    assert :save in Repo.expand_only(:full)
    assert :delete in Repo.expand_only(:full)
    refute :delete in Repo.expand_only(:permanent)
    assert :save in Repo.expand_only(:permanent)
    assert :page in Repo.expand_only(:permanent)
    assert :get_many in Repo.expand_only(:permanent)
    refute :insert in Repo.expand_only(:read)
    refute :save in Repo.expand_only(:read)
    assert :page in Repo.expand_only(:read)
    assert :find_many in Repo.expand_only(:read)
    assert :exists_all? in Repo.expand_only(:read)
    assert Repo.expand_only([:get, :save]) == [:get, :save]
  end

  test "use accepts known only list" do
    Code.eval_quoted(
      quote do
        defmodule Core.RepoTest.Ok do
          use Core.Repo, only: [:get, :save]
        end
      end
    )
  end

  test "use makes caller a behaviour without Core.Repo behaviour" do
    Code.eval_quoted(
      quote do
        defmodule Core.RepoTest.Iface do
          use Core.Repo, only: [:get, :save]
        end
      end
    )

    callbacks =
      Core.RepoTest.Iface.behaviour_info(:callbacks)
      |> Enum.sort()

    assert callbacks == [get: 4, save: 3]

    behaviours =
      Core.RepoTest.Iface.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    refute Core.Repo in behaviours
  end

  test "use accepts view and id for a read behaviour" do
    Code.eval_quoted(
      quote do
        defmodule Core.RepoTest.ReadIface do
          use Core.Repo,
            only: :read,
            view: Core.RepoTest.SampleView,
            id: Core.RepoTest.SampleID
        end
      end
    )

    callbacks = Core.RepoTest.ReadIface.behaviour_info(:callbacks)

    assert {:get, 4} in callbacks
    assert {:page, 4} in callbacks
    refute {:save, 3} in callbacks
    refute {:delete, 4} in callbacks
  end

  test "use accepts entity for a write behaviour" do
    Code.eval_quoted(
      quote do
        defmodule Core.RepoTest.WriteIface do
          use Core.Repo,
            only: :full,
            entity: Core.RepoTest.SampleEntity,
            id: Core.RepoTest.SampleID
        end
      end
    )

    assert {:save, 3} in Core.RepoTest.WriteIface.behaviour_info(:callbacks)
  end

  test "use rejects view together with write methods" do
    assert_raise CompileError, ~r/view: допустим только для read-методов/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.RepoTest.ViewWithWrite do
            use Core.Repo,
              only: [:get, :save],
              view: Core.RepoTest.SampleView
          end
        end
      )
    end

    assert_raise CompileError, ~r/view: допустим только для read-методов/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.RepoTest.ViewWithDelete do
            use Core.Repo,
              only: [:get, :delete],
              view: Core.RepoTest.SampleView
          end
        end
      )
    end
  end

  test "use rejects entity and view together" do
    assert_raise CompileError, ~r/взаимоисключающие/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.RepoTest.BothTypes do
            use Core.Repo,
              only: :read,
              entity: Core.RepoTest.SampleEntity,
              view: Core.RepoTest.SampleView
          end
        end
      )
    end
  end

  test "use rejects non-module view" do
    assert_raise CompileError, ~r/ожидается модуль/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.RepoTest.BadView do
            use Core.Repo, only: :read, view: "view"
          end
        end
      )
    end
  end

  test "use rejects unknown method" do
    assert_raise CompileError, ~r/unknown method\(s\): \[:foo\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.RepoTest.BadMethod do
            use Core.Repo, only: [:get, :foo]
          end
        end
      )
    end
  end

  test "use rejects unknown repository kind" do
    assert_raise CompileError, ~r/unknown repository kind: :weird/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.RepoTest.BadKind do
            use Core.Repo, only: :weird
          end
        end
      )
    end
  end
end
