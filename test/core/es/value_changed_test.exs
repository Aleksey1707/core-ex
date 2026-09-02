defmodule Core.Es.ValueChangedTest do
  use ExUnit.Case, async: true

  alias Core.Prim

  defmodule SampleName do
    @moduledoc false
    use Prim.String, name: "Имя", min_len: 3, max_len: 100
  end

  defmodule SamplePrice do
    @moduledoc false
    use Prim.Decimal, name: "Цена", min: Decimal.new("0.01"), scale: 2
  end

  defmodule Sample do
    @moduledoc false
    use Core.Es.ValueChanged,
      type: SampleName
  end

  defmodule NilableSample do
    @moduledoc false
    use Core.Es.ValueChanged,
      type: SamplePrice,
      nilable: true
  end

  test "new/2 с обязательным type" do
    old = SampleName.new!("old-name")
    new = SampleName.new!("new-name")

    assert %Sample{old_value: ^old, new_value: ^new} = Sample.new(old, new)
  end

  test "new/2 с nilable" do
    price = SamplePrice.new!("10.00")

    assert %NilableSample{old_value: nil, new_value: ^price} = NilableSample.new(nil, price)
    assert %NilableSample{old_value: ^price, new_value: nil} = NilableSample.new(price, nil)
    assert %NilableSample{old_value: nil, new_value: nil} = NilableSample.new(nil, nil)
  end
end
