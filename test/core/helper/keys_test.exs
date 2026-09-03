defmodule Core.Helper.KeysTest do
  use ExUnit.Case, async: true

  alias Core.Helper

  test "camelize рекурсивно переводит ключи в camelCase" do
    assert Helper.Keys.camelize(%{"aggregate_id" => 1, :created_at => "x"}) == %{
             "aggregateId" => 1,
             "createdAt" => "x"
           }

    assert Helper.Keys.camelize(%{"steps" => [%{"sent_at" => 1}]}) == %{
             "steps" => [%{"sentAt" => 1}]
           }
  end

  test "snakify рекурсивно переводит ключи в snake_case" do
    assert Helper.Keys.snakify(%{"aggregateId" => 1, :createdAt => "x"}) == %{
             "aggregate_id" => 1,
             "created_at" => "x"
           }

    assert Helper.Keys.snakify(%{"steps" => [%{"sentAt" => 1}]}) == %{
             "steps" => [%{"sent_at" => 1}]
           }
  end

  test "struct — значение, а не вложенная map" do
    at = ~U[2026-09-03 00:00:00Z]
    sum = Decimal.new("1.5")

    assert Helper.Keys.camelize(%{"created_at" => at, "total_sum" => sum}) == %{
             "createdAt" => at,
             "totalSum" => sum
           }

    assert Helper.Keys.snakify(%{"createdAt" => at}) == %{"created_at" => at}
  end

  test "скаляры и nil проходят как есть" do
    for value <- ["as_is", nil, 42, :atom] do
      assert Helper.Keys.camelize(value) == value
      assert Helper.Keys.snakify(value) == value
    end
  end

  test "snakify обратен camelize на snake_case-ключах" do
    source = %{
      "id" => 1,
      "aggregate_id" => 2,
      "created_at" => "x",
      "steps" => [%{"sent_at" => 1, "owner_id" => 2}]
    }

    camelized = Helper.Keys.camelize(source)

    assert Helper.Keys.snakify(camelized) == source
  end

  test "преобразование одного ключа принимает atom и строку" do
    assert Helper.Keys.camelize_key(:aggregate_id) == "aggregateId"
    assert Helper.Keys.camelize_key("aggregate_id") == "aggregateId"
    assert Helper.Keys.camelize_key("id") == "id"

    assert Helper.Keys.snakify_key(:aggregateId) == "aggregate_id"
    assert Helper.Keys.snakify_key("aggregateId") == "aggregate_id"
    assert Helper.Keys.snakify_key("ID") == "i_d"
    assert Helper.Keys.snakify_key("already_snake") == "already_snake"
  end
end
