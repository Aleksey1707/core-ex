defmodule Core.Prim.DateTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Exc
  alias Core.Prim

  @app_tz Application.compile_env!(:core, :tz)

  defmodule ArrivalDate do
    use Core.Prim.Date,
      name: "Дата поступления",
      after: ~D[2020-01-01],
      before: ~D[2030-01-01]
  end

  defmodule PlainDay do
    use Core.Prim.Date,
      name: "Дата без границ"
  end

  defmodule UtcDay do
    use Core.Prim.Date,
      name: "Дата UTC",
      tz: "Etc/UTC"
  end

  defmodule LabelDay do
    use Core.Prim.Date,
      name: "Дата с kind",
      kind: :label_day
  end

  defmodule PlainAt do
    use Core.Prim.DateTime,
      name: "Момент"
  end

  defmodule FakeDay do
    defstruct [:value]
  end

  test "casts Date and ISO8601 string" do
    assert {:ok, %ArrivalDate{value: ~D[2024-06-01]}} = ArrivalDate.new(~D[2024-06-01])
    assert {:ok, %ArrivalDate{value: ~D[2024-06-01]}} = ArrivalDate.new("2024-06-01")
  end

  test "rejects invalid cast" do
    assert {:error, %Error{kind: :domain, message: "Дата поступления: невалидное значение"}} =
             ArrivalDate.new("not-a-date")
  end

  test "rejects calendar-invalid date" do
    assert {:error, %Error{kind: :domain, code: :invalid_date}} = ArrivalDate.new("2024-02-31")
  end

  test "new/1 does not accept a datetime" do
    assert {:error, %Error{kind: :domain, code: :invalid_date}} =
             ArrivalDate.new(~U[2024-06-01 12:00:00Z])
  end

  test "validates after" do
    assert {:error, %Error{kind: :domain, message: "Дата поступления: слишком ранняя дата"}} =
             ArrivalDate.new(~D[2019-12-31])
  end

  test "validates before" do
    assert {:error, %Error{kind: :domain, message: "Дата поступления: слишком поздняя дата"}} =
             ArrivalDate.new(~D[2030-01-02])
  end

  test "bounds are inclusive" do
    assert {:ok, %ArrivalDate{}} = ArrivalDate.new(~D[2020-01-01])
    assert {:ok, %ArrivalDate{}} = ArrivalDate.new(~D[2030-01-01])
  end

  test "new!/1 and value/1" do
    date = ArrivalDate.new!(~D[2024-06-01])
    assert ArrivalDate.value(date) == ~D[2024-06-01]
  end

  test "new!/1 raises on invalid value" do
    assert_raise Exc, fn -> ArrivalDate.new!("not-a-date") end
  end

  test "domain kind is :date and is native" do
    assert :date = ArrivalDate.__domain_kind__()
    assert :date in Prim.native_kinds()
  end

  test "custom kind is kept" do
    assert :label_day = LabelDay.__domain_kind__()
  end

  test "__domain_type_opts__/0 exposes tz and bounds" do
    assert "Etc/UTC" = Keyword.fetch!(UtcDay.__domain_type_opts__(), :tz)
    assert ~D[2020-01-01] = Keyword.fetch!(ArrivalDate.__domain_type_opts__(), :after)
    assert [] = PlainDay.__domain_type_opts__()
  end

  test "today/0 uses config tz" do
    {:ok, now} = DateTime.now(@app_tz)
    assert {:ok, %PlainDay{value: value}} = PlainDay.today()
    assert value == DateTime.to_date(now)
  end

  test "today/0 uses explicit tz" do
    {:ok, utc_now} = DateTime.now("Etc/UTC")
    assert {:ok, %UtcDay{value: value}} = UtcDay.today()
    assert value == DateTime.to_date(utc_now)
  end

  test "today!/0 returns date prim" do
    assert %PlainDay{value: %Date{}} = PlainDay.today!()
  end

  test "from/1 converts another date prim" do
    source = PlainDay.new!(~D[2024-06-01])
    assert {:ok, %ArrivalDate{value: ~D[2024-06-01]}} = ArrivalDate.from(source)
  end

  test "from/1 converts a datetime prim in config tz" do
    at = ~U[2024-06-01 20:00:00Z]

    expected =
      at
      |> DateTime.shift_zone!(@app_tz)
      |> DateTime.to_date()

    source = PlainAt.new!(at)
    assert {:ok, %PlainDay{value: ^expected}} = PlainDay.from(source)
  end

  test "from/1 converts a datetime prim in explicit tz" do
    source = PlainAt.new!(~U[2024-06-01 20:00:00Z])
    assert {:ok, %UtcDay{value: ~D[2024-06-01]}} = UtcDay.from(source)
  end

  test "from/1 runs target validations" do
    source = PlainDay.new!(~D[2019-01-01])

    assert {:error, %Error{kind: :domain, message: "Дата поступления: слишком ранняя дата"}} =
             ArrivalDate.from(source)
  end

  test "from!/1 converts another date prim" do
    source = PlainDay.new!(~D[2024-06-01])
    assert %ArrivalDate{value: ~D[2024-06-01]} = ArrivalDate.from!(source)
  end

  test "from/1 rejects non-prim struct with Date value" do
    assert {:error,
            %Error{
              kind: :domain,
              code: :invalid_date,
              message: "Дата поступления: невалидное значение"
            }} = ArrivalDate.from(%FakeDay{value: ~D[2024-06-01]})
  end

  test "rejects unknown option at compile time" do
    assert_raise CompileError, ~r/unknown option/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.DateTest.BadOption do
            use Core.Prim.Date,
              name: "Дата",
              precision: :second
          end
        end
      )
    end
  end

  test "rejects builtin kind of another wrapper" do
    assert_raise ArgumentError, ~r/is a builtin kind/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.DateTest.BadKind do
            use Core.Prim.Date,
              name: "Дата",
              kind: :datetime
          end
        end
      )
    end
  end
end
