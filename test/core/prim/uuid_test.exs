defmodule Core.Prim.UUIDTest do
  use ExUnit.Case, async: true

  defmodule Id do
    use Core.Prim.UUID, name: "Идентификатор", version: 4
  end

  defmodule IdV1 do
    use Core.Prim.UUID, name: "ID v1", version: 1
  end

  defmodule IdV7 do
    use Core.Prim.UUID, name: "ID v7", version: 7
  end

  defmodule IdV3 do
    use Core.Prim.UUID, name: "ID v3", version: 3
  end

  defmodule AnyVersion do
    use Core.Prim.UUID, name: "ID", version: nil
  end

  defmodule IdV7NoCheck do
    use Core.Prim.UUID,
      name: "ID v7",
      version: 7,
      check_version: false
  end

  @uuid4 "550e8400-e29b-41d4-a716-446655440000"
  @uuid1 "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

  test "casts valid uuid string" do
    assert {:ok, %Id{value: @uuid4}} = Id.new(@uuid4)
  end

  test "rejects invalid cast" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Идентификатор: невалидное значение"
            }} = Id.new("not-a-uuid")
  end

  test "validates version" do
    assert {:error, %Core.Error{kind: :domain, code: :version}} = Id.new(@uuid1)
    assert {:ok, %AnyVersion{}} = AnyVersion.new(@uuid1)
  end

  test "check_version: false skips version validation on construct" do
    assert {:ok, %IdV7NoCheck{}} = IdV7NoCheck.new(@uuid4)
    assert {:ok, %IdV7NoCheck{}} = IdV7NoCheck.new(@uuid1)
  end

  test "check_version: false still generates configured version" do
    id = IdV7NoCheck.new()
    assert {:ok, info} = UUID.info(IdV7NoCheck.value(id))
    assert Keyword.get(info, :version) == 7
  end

  test "new!/1 and value/1" do
    assert @uuid4 = Id.value(Id.new!(@uuid4))
  end

  test "new/0 generates uuid v4" do
    id = Id.new()
    assert %Id{} = id
    assert {:ok, info} = UUID.info(Id.value(id))
    assert Keyword.get(info, :version) == 4
  end

  test "new/0 generates uuid v1" do
    id = IdV1.new()
    assert {:ok, info} = UUID.info(IdV1.value(id))
    assert Keyword.get(info, :version) == 1
  end

  test "new/0 generates uuid v7" do
    id = IdV7.new()
    assert {:ok, info} = UUID.info(IdV7.value(id))
    assert Keyword.get(info, :version) == 7
  end

  test "new/0 raises for unsupported version" do
    assert_raise ArgumentError, ~r/unsupported UUID version/, fn -> IdV3.new() end
  end

  test "new/0 with version nil generates v4" do
    id = AnyVersion.new()
    assert {:ok, info} = UUID.info(AnyVersion.value(id))
    assert Keyword.get(info, :version) == 4
  end

  test "format/2 full hex urn" do
    id = Id.new!(@uuid4)

    assert Id.format(id, :full) == @uuid4
    assert Id.format(id, :hex) == "550e8400e29b41d4a716446655440000"
    assert Id.format(id, :urn) == "urn:uuid:550e8400-e29b-41d4-a716-446655440000"
  end

  test "round-trip via hex and urn" do
    id = Id.new()
    assert {:ok, from_hex} = Id.new(Id.format(id, :hex))
    assert {:ok, from_urn} = Id.new(Id.format(id, :urn))
    assert from_hex == id
    assert from_urn == id
  end

  test "generate/0 — UUID v4 без аргумента" do
    uuid = Core.Prim.UUID.generate()

    assert String.length(uuid) == 36
    assert <<_::binary-14, "4", _::binary>> = uuid
  end
end
