defmodule Core.Outbox.PartitionTest do
  use ExUnit.Case, async: true

  alias Core.Outbox

  test "topics_filter/1: :all, {:only, строки} или {:except, строки}" do
    for good <- [:all, {:only, ["orders"]}, {:except, []}] do
      assert Outbox.topics_filter(good) == {:ok, good}
    end

    for bad <- [["orders"], {:only, "orders"}, {:only, [:orders]}, {:all, ["orders"]}, nil] do
      assert {:error, "ожидается :all, {:only, [String.t()]} или {:except, [String.t()]}, получено " <> _} =
               Outbox.topics_filter(bad)
    end
  end

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
end
