defmodule Core.Es.ValueChangedTest do
  use ExUnit.Case, async: true

  alias Core.Prim

  defmodule SampleName do
    @moduledoc false
    use Prim.String,
      name: "Имя",
      min_len: 3,
      max_len: 100
  end

  defmodule SamplePrice do
    @moduledoc false
    use Prim.Decimal,
      name: "Цена",
      min: Decimal.new("0.01"),
      scale: 2
  end

  defmodule Sample do
    @moduledoc false
    use Core.Es.ValueChanged,
      type: SampleName
  end

  defmodule SampleStatus do
    @moduledoc false
    use Core.Enum,
      name: "Статус",
      values: ~w(draft active)a
  end

  defmodule EnumSample do
    @moduledoc false
    use Core.Es.ValueChanged,
      type: SampleStatus
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

  test "new/2 с enum-типом — атом, без nil" do
    assert %EnumSample{old_value: :draft, new_value: :active} = EnumSample.new(:draft, :active)

    assert_raise FunctionClauseError, fn -> EnumSample.new(nil, :active) end
    assert_raise FunctionClauseError, fn -> EnumSample.new("draft", :active) end
  end

  test "голова new/2 закрывает тип значения" do
    assert_raise FunctionClauseError, fn -> Sample.new(SamplePrice.new!("10.00"), SampleName.new!("new-name")) end
    assert_raise FunctionClauseError, fn -> Sample.new(nil, SampleName.new!("new-name")) end
  end

  test "__es_value_changed__/0 отдаёт type: и nilable:" do
    assert Sample.__es_value_changed__() == [type: SampleName, nilable: false]
    assert NilableSample.__es_value_changed__() == [type: SamplePrice, nilable: true]
  end

  describe "опции use" do
    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es.ValueChanged: неизвестные опции: \[:nilabel\]$/, fn ->
        {:ok, env} = Macro.Env.define_require(__ENV__, [], Core.Es.ValueChanged)
        Macro.expand(quote(do: Core.Es.ValueChanged.__using__(type: SampleName, nilabel: true)), env)
      end
    end

    test "атрибут в type: — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Es.ValueChanged: type: ожидается литерал, получено @type_mod$/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.ValueChangedTest.AttrType do
              @type_mod Core.Es.ValueChangedTest.SampleName
              use Core.Es.ValueChanged, type: @type_mod
            end
          end
        )
      end
    end

    test "type: — только модуль" do
      assert_raise CompileError, ~r/^Es.ValueChanged: type: ожидается модуль, получено "x"$/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.ValueChangedTest.StringType do
              use Core.Es.ValueChanged, type: "x"
            end
          end
        )
      end
    end

    test "nilable: — только boolean" do
      assert_raise CompileError, ~r/^Es.ValueChanged: nilable: ожидается boolean, получено :yes$/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.ValueChangedTest.AtomNilable do
              use Core.Es.ValueChanged,
                type: Core.Es.ValueChangedTest.SampleName,
                nilable: :yes
            end
          end
        )
      end
    end
  end

  describe "declared/1" do
    test "type: и nilable: модуля, который ещё собирается; модуль без use — nil" do
      defmodule DeclaredChange do
        @moduledoc false
        use Core.Es.ValueChanged,
          type: Core.Es.ValueChangedTest.SampleName,
          nilable: true

        @declared Core.Es.ValueChanged.declared(__MODULE__)

        def declared, do: @declared
      end

      defmodule UndeclaredChange do
        @moduledoc false
        defstruct [:old_value, :new_value]

        @declared Core.Es.ValueChanged.declared(__MODULE__)

        def declared, do: @declared
      end

      assert DeclaredChange.declared() == [type: SampleName, nilable: true]
      assert UndeclaredChange.declared() == nil
    end
  end
end
