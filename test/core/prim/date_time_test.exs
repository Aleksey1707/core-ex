defmodule Core.Prim.DateTimeTest do
  use ExUnit.Case, async: true

  @app_tz Application.compile_env!(:core, :tz)

  defmodule EventAt do
    use Core.Prim.DateTime,
      name: "Дата события",
      after: ~U[2020-01-01 00:00:00Z],
      before: ~U[2030-01-01 00:00:00Z]
  end

  defmodule MoscowAt do
    use Core.Prim.DateTime, name: "Дата", tz: "Europe/Moscow"
  end

  defmodule PlainAt do
    use Core.Prim.DateTime, name: "Дата без границ"
  end

  defmodule MillisecondAt do
    use Core.Prim.DateTime, name: "Дата ms", precision: :millisecond
  end

  defmodule MicrosecondAt do
    use Core.Prim.DateTime, name: "Дата us", precision: :microsecond
  end

  defmodule FakeAt do
    defstruct [:value]
  end

  defp dt_with_us(us) do
    %DateTime{
      year: 2024,
      month: 6,
      day: 1,
      hour: 12,
      minute: 0,
      second: 0,
      utc_offset: 0,
      std_offset: 0,
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      microsecond: us
    }
  end

  test "casts DateTime and ISO8601 string" do
    assert {:ok, %EventAt{}} = EventAt.new(~U[2024-06-01 12:00:00Z])
    assert {:ok, %EventAt{}} = EventAt.new("2024-06-01T12:00:00Z")
  end

  test "shifts to config tz when tz is not set" do
    assert {:ok, %EventAt{value: value}} = EventAt.new(~U[2024-06-01 12:00:00Z])
    assert value.time_zone == @app_tz
  end

  test "shifts to explicit tz" do
    assert {:ok, %MoscowAt{value: value}} = MoscowAt.new(~U[2024-06-01 12:00:00Z])
    assert value.time_zone == "Europe/Moscow"
  end

  test "rejects invalid cast" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Дата события: невалидное значение"
            }} = EventAt.new("not-a-date")
  end

  test "validates after" do
    assert {:error, %Core.Error{kind: :domain, message: "Дата события: слишком ранняя дата"}} =
             EventAt.new(~U[2019-01-01 00:00:00Z])
  end

  test "validates before" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Дата события: слишком поздняя дата"
            }} =
             EventAt.new(~U[2031-01-01 00:00:00Z])
  end

  test "new!/1 and value/1" do
    dt = EventAt.new!(~U[2024-06-01 12:00:00Z])
    assert %DateTime{} = EventAt.value(dt)
  end

  test "truncates microseconds to seconds on new/1" do
    assert {:ok, %EventAt{value: value}} = EventAt.new(dt_with_us({123_456, 6}))
    assert value.microsecond == {0, 0}
  end

  test "truncates fractional ISO8601 to seconds" do
    assert {:ok, %EventAt{value: value}} = EventAt.new("2024-06-01T12:00:00.123456Z")
    assert value.microsecond == {0, 0}
  end

  test "precision :millisecond truncates to milliseconds" do
    assert {:ok, %MillisecondAt{value: value}} = MillisecondAt.new(dt_with_us({123_456, 6}))
    assert value.microsecond == {123_000, 3}
  end

  test "precision :microsecond keeps microseconds" do
    assert {:ok, %MicrosecondAt{value: value}} = MicrosecondAt.new(dt_with_us({123_456, 6}))
    assert value.microsecond == {123_456, 6}
  end

  test "precision :microsecond lifts tag from second-precision input" do
    assert {:ok, %MicrosecondAt{value: value}} = MicrosecondAt.new(~U[2024-06-01 12:00:00Z])
    assert value.microsecond == {0, 6}
  end

  test "precision :millisecond lifts tag from second-precision input" do
    assert {:ok, %MillisecondAt{value: value}} = MillisecondAt.new(~U[2024-06-01 12:00:00Z])
    assert value.microsecond == {0, 3}
  end

  test "__domain_type_opts__/0 exposes tz and precision" do
    assert "Europe/Moscow" = Keyword.fetch!(MoscowAt.__domain_type_opts__(), :tz)
    assert :millisecond = Keyword.fetch!(MillisecondAt.__domain_type_opts__(), :precision)
    assert nil == Keyword.get(PlainAt.__domain_type_opts__(), :precision)
  end

  test "from/1 lifts precision tag from coarser datetime prim" do
    source = PlainAt.new!(~U[2024-06-01 12:00:00Z])
    assert {:ok, %MicrosecondAt{value: value}} = MicrosecondAt.from(source)
    assert value.microsecond == {0, 6}
  end

  test "rejects unknown precision at compile time" do
    assert_raise ArgumentError, ~r/unknown precision: :nanosecond/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.DateTimeTest.BadPrecision do
            use Core.Prim.DateTime,
              name: "Дата",
              precision: :nanosecond
          end
        end
      )
    end
  end

  test "now/0 uses config tz" do
    assert {:ok, %EventAt{value: value}} = EventAt.now()
    assert value.time_zone == @app_tz
  end

  test "now/0 uses explicit tz" do
    assert {:ok, %MoscowAt{value: value}} = MoscowAt.now()
    assert value.time_zone == "Europe/Moscow"
  end

  test "now/0 truncates to seconds" do
    assert {:ok, %EventAt{value: value}} = EventAt.now()
    assert value.microsecond == {0, 0}
  end

  test "now!/0 returns datetime prim" do
    assert %EventAt{value: value} = EventAt.now!()
    assert value.time_zone == @app_tz
  end

  test "from/1 converts another datetime prim and applies target tz" do
    source = EventAt.new!(~U[2024-06-01 12:00:00Z])
    assert {:ok, %MoscowAt{value: value}} = MoscowAt.from(source)
    assert value.time_zone == "Europe/Moscow"
  end

  test "from!/1 converts another datetime prim" do
    source = EventAt.new!(~U[2024-06-01 12:00:00Z])
    assert %MoscowAt{value: value} = MoscowAt.from!(source)
    assert value.time_zone == "Europe/Moscow"
  end

  test "from/1 runs target validations" do
    early = PlainAt.new!(~U[2019-01-01 00:00:00Z])

    assert {:error, %Core.Error{kind: :domain, message: "Дата события: слишком ранняя дата"}} =
             EventAt.from(early)
  end

  test "new/1 does not accept another datetime prim" do
    source = EventAt.new!(~U[2024-06-01 12:00:00Z])

    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Дата: невалидное значение"
            }} = MoscowAt.new(source)
  end

  test "from/1 rejects non-prim struct with DateTime value" do
    fake = %FakeAt{value: ~U[2024-06-01 12:00:00Z]}

    assert {:error,
            %Core.Error{
              kind: :domain,
              code: :invalid_datetime,
              message: "Дата события: невалидное значение"
            }} = EventAt.from(fake)
  end
end
