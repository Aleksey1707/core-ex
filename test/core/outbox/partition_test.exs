defmodule Core.Outbox.PartitionTest do
  use ExUnit.Case, async: true

  alias Core.Outbox

  describe "topics_overlap?/2" do
    test ":all пересекается со всем, кроме пустого {:only, []}" do
      assert Outbox.topics_overlap?(:all, :all)
      assert Outbox.topics_overlap?(:all, {:only, ["a"]})
      assert Outbox.topics_overlap?(:all, {:except, ["a"]})
      refute Outbox.topics_overlap?(:all, {:only, []})
      refute Outbox.topics_overlap?({:only, []}, :all)
    end

    test "{:only, _} пересекаются по общему элементу" do
      assert Outbox.topics_overlap?({:only, ["a", "b"]}, {:only, ["b", "c"]})
      refute Outbox.topics_overlap?({:only, ["a"]}, {:only, ["b"]})
    end

    test "{:only, _} против {:except, _}: пересечение, если что-то не исключено" do
      assert Outbox.topics_overlap?({:only, ["a"]}, {:except, ["b"]})
      refute Outbox.topics_overlap?({:only, ["a"]}, {:except, ["a"]})
      refute Outbox.topics_overlap?({:except, ["a", "b"]}, {:only, ["a", "b"]})
    end

    test "два {:except, _} пересекаются всегда: множество топиков открыто" do
      assert Outbox.topics_overlap?({:except, ["a"]}, {:except, ["b"]})
      assert Outbox.topics_overlap?({:except, ["a"]}, {:except, ["a"]})
    end
  end

  describe "validate_partition!/1" do
    test "непересекающиеся {:only, _} проходят" do
      assert :ok =
               Outbox.validate_partition!([
                 [name: A, topics: {:only, ["orders"]}],
                 [name: B, topics: {:only, ["roles", "products"]}]
               ])
    end

    test "одиночный поллер и пустой список проходят" do
      assert :ok = Outbox.validate_partition!([])
      assert :ok = Outbox.validate_partition!([[name: A, topics: :all]])
    end

    test ":only вместе с :all — отказ с именами обоих поллеров" do
      assert_raise ArgumentError, ~r/фильтры топиков поллеров пересекаются/, fn ->
        Outbox.validate_partition!([
          [name: A, topics: {:only, ["orders"]}],
          [name: B, topics: :all]
        ])
      end
    end

    test "общий топик у двух {:only, _} — отказ" do
      error =
        assert_raise ArgumentError, fn ->
          Outbox.validate_partition!([
            [name: A, topics: {:only, ["orders", "roles"]}],
            [name: B, topics: {:only, ["roles"]}]
          ])
        end

      assert error.message =~ "A"
      assert error.message =~ "B"
      assert error.message =~ "roles"
    end

    test "пересечение ищется по всем парам, не только по соседним" do
      assert_raise ArgumentError, fn ->
        Outbox.validate_partition!([
          [name: A, topics: {:only, ["a"]}],
          [name: B, topics: {:only, ["b"]}],
          [name: C, topics: {:only, ["a"]}]
        ])
      end
    end

    test "{:except, _} и покрывающий его {:only, _} совместимы" do
      assert :ok =
               Outbox.validate_partition!([
                 [name: A, topics: {:only, ["orders"]}],
                 [name: B, topics: {:except, ["orders"]}]
               ])
    end
  end
end
