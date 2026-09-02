defmodule Core.Prim.ComposeTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Prim

  defmodule BaseID do
    use Prim.UUID, name: "ID", version: 4
  end

  defmodule ApproverID do
    use Prim.Compose,
      name: "Согласующий",
      of: BaseID
  end

  defmodule NestedApproverID do
    use Prim.Compose,
      name: "Вложенный",
      of: ApproverID
  end

  defmodule ValidatedApproverID do
    use Prim.Compose,
      name: "Проверенный",
      of: BaseID,
      mutate: &Core.Prim.ComposeTest.identity_mutate/1,
      validate: &Core.Prim.ComposeTest.reject_nil_value/1
  end

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  def identity_mutate(value), do: {:ok, value}

  def reject_nil_value(%BaseID{}), do: :ok
  def reject_nil_value(_), do: {:error, {:invalid_value, "ожидался BaseID"}}

  test "new/1 from raw string" do
    assert {:ok, %ApproverID{value: %BaseID{value: @uuid}}} = ApproverID.new(@uuid)
  end

  test "new/1 from base Prim" do
    base = BaseID.new!(@uuid)
    assert {:ok, %ApproverID{value: ^base}} = ApproverID.new(base)
  end

  test "new/1 from self is idempotent" do
    {:ok, outer} = ApproverID.new(@uuid)
    assert {:ok, ^outer} = ApproverID.new(outer)
  end

  test "value/1 returns base Prim" do
    {:ok, prim} = ApproverID.new(@uuid)
    assert %BaseID{value: @uuid} = ApproverID.value(prim)
  end

  test "__domain_base__/0 and kind :composite" do
    assert ApproverID.__domain_base__() == BaseID
    assert ApproverID.__domain_kind__() == :composite
    assert Prim.composed?(ApproverID)
    refute Prim.composed?(BaseID)
  end

  test "raw/1 unwraps to leaf value" do
    {:ok, prim} = ApproverID.new(@uuid)
    assert ApproverID.raw(prim) == @uuid
  end

  test "nested compose" do
    assert {:ok, %NestedApproverID{value: %ApproverID{value: %BaseID{value: @uuid}}}} =
             NestedApproverID.new(@uuid)

    nested = NestedApproverID.new!(@uuid)
    assert NestedApproverID.raw(nested) == @uuid
    assert Prim.unwrap(nested) == @uuid
  end

  test "nested compose from intermediate Prim" do
    mid = ApproverID.new!(@uuid)
    assert {:ok, %NestedApproverID{value: ^mid}} = NestedApproverID.new(mid)
  end

  test "custom_mutate and custom_validate" do
    assert {:ok, %ValidatedApproverID{}} = ValidatedApproverID.new(@uuid)
  end

  test "base error is wrapped with parent chain" do
    assert {:error,
            %Error{
              kind: :domain,
              ns: :prim,
              code: :invalid_uuid,
              message: "Согласующий: ID: невалидное значение",
              parent: %Error{module: BaseID, code: :invalid_uuid}
            }} = ApproverID.new("not-a-uuid")
  end

  test "rejects of: non-Prim at compile time" do
    assert_raise CompileError, ~r/of: must be a Prim module/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.ComposeTest.BadOf do
            use Core.Prim.Compose,
              name: "X",
              of: String
          end
        end
      )
    end
  end

  test "rejects reserved kind :uuid" do
    assert_raise ArgumentError, ~r/builtin kind/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.ComposeTest.BadKind do
            use Core.Prim.Compose,
              name: "X",
              of: Core.Prim.ComposeTest.BaseID,
              kind: :uuid
          end
        end
      )
    end
  end
end
