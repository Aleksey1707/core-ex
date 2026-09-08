defmodule Core.CodecTest do
  use ExUnit.Case, async: true

  alias Core.Codec
  alias Core.Codec.Helper
  alias Core.Exc
  alias Core.Prim

  @app_tz Application.compile_env!(:core, :tz)

  defmodule BuiltinProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :keep,
      decimal: :string
  end

  defmodule InternalLike do
    use Core.Codec,
      uuid: :full,
      datetime: :datetime,
      datetime_tz: "Etc/UTC",
      decimal: :decimal
  end

  defmodule SampleUUID do
    use Prim.UUID, name: "ID", version: 4
  end

  defmodule SampleString do
    use Prim.String, name: "Имя", min_len: 1, max_len: 50
  end

  defmodule SampleInteger do
    use Prim.Integer, name: "Число", min: 0
  end

  defmodule SampleDecimal do
    use Prim.Decimal, name: "Цена", min: 0
  end

  defmodule SampleDateTime do
    use Prim.DateTime, name: "Момент"
  end

  defmodule SampleDate do
    use Prim.Date, name: "Дата"
  end

  defmodule LabelID do
    use Prim.UUID, name: "Label", version: 4, kind: :label
  end

  defmodule MicroAt do
    use Prim.DateTime, name: "Момент us", precision: :microsecond
  end

  defmodule MoscowAt do
    use Prim.DateTime, name: "Момент МСК", tz: "Europe/Moscow"
  end

  defmodule ApproverID do
    use Prim.Compose, name: "Согласующий", of: SampleUUID
  end

  defmodule WrappedLabelID do
    use Prim.Compose, name: "Обёртка", of: SampleUUID, kind: :wrapped_label
  end

  defmodule PriorityProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :keep,
      decimal: :string

    @impl true
    def dump(%LabelID{} = prim) do
      "mod:" <> Prim.UUID.format(Codec.value(prim), :hex)
    end

    @impl true
    def dump(%WrappedLabelID{} = prim) do
      "mod:" <> Prim.UUID.format(Prim.unwrap(prim), :hex)
    end

    @impl true
    def dump_kind(prim, :label) do
      "kind:" <> Prim.UUID.format(Codec.value(prim), :hex)
    end

    @impl true
    def dump_kind(prim, :wrapped_label) do
      "kind:" <> Prim.UUID.format(Prim.unwrap(prim), :hex)
    end

    @impl true
    def dump_kind(prim, kind), do: super(prim, kind)
  end

  defmodule KindOnlyProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :keep,
      decimal: :string

    @impl true
    def dump_kind(prim, :label) do
      "kind:" <> Prim.UUID.format(Codec.value(prim), :hex)
    end

    @impl true
    def dump_kind(prim, :wrapped_label) do
      "kind:" <> Prim.UUID.format(Prim.unwrap(prim), :hex)
    end

    @impl true
    def dump_kind(prim, kind), do: super(prim, kind)
  end

  defmodule RawOverrideProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :keep,
      decimal: :string

    @impl true
    def dump_kind(prim, :uuid), do: "raw:" <> Prim.UUID.format(Codec.value(prim), :hex)

    @impl true
    def dump_kind(prim, kind), do: super(prim, kind)
  end

  defmodule PlainOverrideProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :keep,
      decimal: :string

    @impl true
    def dump(%SampleString{} = prim), do: "str:" <> Codec.value(prim)
  end

  defmodule IsoUtcProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: "Etc/UTC",
      decimal: :string
  end

  defmodule IsoOffsetTzProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: "Europe/Moscow",
      decimal: :string
  end

  defmodule AppTzProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :app,
      decimal: :string
  end

  defmodule DateIsoProfile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :keep,
      date: :iso8601,
      decimal: :string
  end

  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @date ~D[2024-06-01]

  test "builtin kinds on wrappers" do
    assert :uuid = SampleUUID.__domain_kind__()
    assert :string = SampleString.__domain_kind__()
    assert :integer = SampleInteger.__domain_kind__()
    assert :decimal = SampleDecimal.__domain_kind__()
    assert :datetime = SampleDateTime.__domain_kind__()
    assert :date = SampleDate.__domain_kind__()
  end

  test "dump uuid hex and full" do
    id = SampleUUID.new!(@uuid)
    assert BuiltinProfile.dump(id) == "550e8400e29b41d4a716446655440000"
    assert InternalLike.dump(id) == @uuid
  end

  test "dump string and integer" do
    assert BuiltinProfile.dump(SampleString.new!("ab")) == "ab"
    assert BuiltinProfile.dump(SampleInteger.new!(3)) == 3
  end

  test "dump decimal and string" do
    price = SampleDecimal.new!(Decimal.new("10.5"))
    assert InternalLike.dump(price) == Decimal.new("10.5")
    assert BuiltinProfile.dump(price) == Decimal.to_string(Decimal.new("10.5"))
  end

  test "dump datetime :datetime + Etc/UTC and :iso8601 + :keep" do
    dt = SampleDateTime.now!()
    utc = InternalLike.dump(dt)
    assert %DateTime{time_zone: "Etc/UTC"} = utc

    iso = BuiltinProfile.dump(dt)
    assert is_binary(iso)
    assert {:ok, _, offset} = DateTime.from_iso8601(iso)
    assert offset == tz_offset_seconds(@app_tz, Codec.value(dt))
  end

  test "dump datetime :iso8601 + Etc/UTC yields Z" do
    dt = SampleDateTime.now!()
    iso = IsoUtcProfile.dump(dt)
    assert String.ends_with?(iso, "Z")
  end

  test "dump datetime :iso8601 + Europe/Moscow yields offset" do
    dt = SampleDateTime.now!()
    iso = IsoOffsetTzProfile.dump(dt)
    assert {:ok, _, offset} = DateTime.from_iso8601(iso)
    assert offset == tz_offset_seconds("Europe/Moscow", Codec.value(dt))
  end

  test "dump datetime :iso8601 + :app shifts raw UTC into the app timezone" do
    utc = ~U[2026-08-31 10:00:00Z]
    iso = Helper.dump_raw(SampleDateTime, utc, AppTzProfile)

    assert {:ok, _, offset} = DateTime.from_iso8601(iso)
    assert offset == tz_offset_seconds(@app_tz, utc)
  end

  test "dump datetime :app: raw path matches prim path" do
    utc = ~U[2026-08-31 10:00:00Z]
    prim = SampleDateTime.new!(utc)

    assert Helper.dump_raw(SampleDateTime, utc, AppTzProfile) == AppTzProfile.dump(prim)
    assert {:ok, ^prim} = AppTzProfile.load(SampleDateTime, AppTzProfile.dump(prim))
  end

  test "dump date :date and :iso8601" do
    date = SampleDate.new!(@date)
    assert InternalLike.dump(date) == @date
    assert DateIsoProfile.dump(date) == "2024-06-01"
  end

  test "profile without date option defaults to :date" do
    date = SampleDate.new!(@date)
    assert BuiltinProfile.dump(date) == @date
  end

  test "переопределение dump_kind применяется и к raw-пути" do
    id = SampleUUID.new!(@uuid)
    raw = "raw:550e8400e29b41d4a716446655440000"

    assert RawOverrideProfile.dump(id) == raw
    assert Helper.dump_raw(SampleUUID, Codec.value(id), RawOverrideProfile) == raw
  end

  describe "coerce/2" do
    test "приводит значение к своему Prim" do
      assert {:ok, %SampleUUID{}} = Codec.coerce(SampleUUID, @uuid)
      assert {:ok, %SampleDate{}} = Codec.coerce(SampleDate, @date)
      assert {:ok, %SampleDecimal{}} = Codec.coerce(SampleDecimal, Decimal.new("10.5"))
      assert {:ok, %SampleDateTime{}} = Codec.coerce(SampleDateTime, DateTime.utc_now())
    end

    test "точность и tz берутся у Prim, а не у значения" do
      raw = ~U[2024-06-01 12:00:00.123456Z]

      assert {:ok, second} = Codec.coerce(SampleDateTime, raw)
      assert {:ok, micro} = Codec.coerce(MicroAt, raw)
      assert Codec.value(second).microsecond == {0, 0}
      assert Codec.value(micro).microsecond == {123_456, 6}

      assert {:ok, moscow} = Codec.coerce(MoscowAt, ~U[2024-06-01 12:00:00Z])
      assert Codec.value(moscow).time_zone == "Europe/Moscow"
    end

    test "восстанавливает цепочку Prim.Compose" do
      assert {:ok, %ApproverID{value: %SampleUUID{}} = composed} = Codec.coerce(ApproverID, @uuid)
      assert composed == ApproverID.new!(@uuid)
    end

    test "plain-kind оборачивается как есть: приводить нечего, но dump/1 профиля нужен" do
      assert {:ok, %SampleString{value: "Иван"}} = Codec.coerce(SampleString, "Иван")
      assert {:ok, %SampleInteger{value: 3}} = Codec.coerce(SampleInteger, 3)
    end

    test "приведению не подлежит: nil, не-Prim, кастомный kind, кривое значение" do
      assert :error = Codec.coerce(SampleDateTime, nil)
      assert :error = Codec.coerce(DateTime, @uuid)
      assert :error = Codec.coerce(LabelID, @uuid)
      assert :error = Codec.coerce(SampleUUID, "zz")
      assert :error = Codec.coerce(SampleDateTime, "не дата")
    end
  end

  describe "coercible?/1" do
    test "kind leaf-примитива из coercible_kinds" do
      assert Codec.coercible?(SampleUUID)
      assert Codec.coercible?(SampleString)
      assert Codec.coercible?(SampleInteger)
      assert Codec.coercible?(ApproverID)
    end

    test "не Prim или кастомный kind leaf-примитива — нет" do
      refute Codec.coercible?(DateTime)
      refute Codec.coercible?(LabelID)
    end

    test "кастомный kind самого композита приводимости не отменяет" do
      assert Codec.coercible?(WrappedLabelID)
      assert {:ok, %WrappedLabelID{}} = Codec.coerce(WrappedLabelID, @uuid)
    end

    test "coercible_kinds — форматируемые профилем плюс plain" do
      assert Codec.coercible_kinds() == ~w(date datetime decimal uuid integer string)a
    end
  end

  describe "Codec.Helper.dump_many/2 и dump_optional/2" do
    test "дампит каждый элемент списка профилем" do
      ids = [SampleUUID.new!(@uuid), SampleUUID.new!(@uuid)]

      assert Helper.dump_many(ids, BuiltinProfile) == Enum.map(ids, &BuiltinProfile.dump/1)
      assert [] == Helper.dump_many([], BuiltinProfile)
    end

    test "опциональное значение: nil проходит, Prim дампится" do
      id = SampleUUID.new!(@uuid)

      assert nil == Helper.dump_optional(nil, BuiltinProfile)
      assert Helper.dump_optional(id, BuiltinProfile) == BuiltinProfile.dump(id)
    end
  end

  describe "Codec.Helper.dump_raw/3" do
    test "формат совпадает с дампом того же Prim" do
      id = SampleUUID.new!(@uuid)
      price = SampleDecimal.new!(Decimal.new("10.5"))
      date = SampleDate.new!(@date)
      dt = SampleDateTime.now!()

      for profile <- [BuiltinProfile, InternalLike, DateIsoProfile, AppTzProfile] do
        assert Helper.dump_raw(SampleUUID, Codec.value(id), profile) == profile.dump(id)
        assert Helper.dump_raw(SampleDecimal, Codec.value(price), profile) == profile.dump(price)
        assert Helper.dump_raw(SampleDate, Codec.value(date), profile) == profile.dump(date)
        assert Helper.dump_raw(SampleDateTime, Codec.value(dt), profile) == profile.dump(dt)
      end
    end

    test "принимает wire-форму значения (строку из jsonb)" do
      iso = "2024-06-01T12:00:00Z"
      hex = "550e8400e29b41d4a716446655440000"

      assert Helper.dump_raw(SampleDateTime, iso, AppTzProfile) ==
               AppTzProfile.dump(SampleDateTime.new!(iso))

      assert Helper.dump_raw(SampleUUID, hex, BuiltinProfile) ==
               BuiltinProfile.dump(SampleUUID.new!(hex))

      assert Helper.dump_raw(SampleDecimal, 10.5, BuiltinProfile) ==
               BuiltinProfile.dump(SampleDecimal.new!(10.5))

      assert Helper.dump_raw(SampleDate, "2024-06-01", DateIsoProfile) ==
               DateIsoProfile.dump(SampleDate.new!(@date))
    end

    test "рекурсия по Prim.Compose до базового Prim" do
      id = ApproverID.new!(@uuid)

      assert Helper.dump_raw(ApproverID, @uuid, BuiltinProfile) == BuiltinProfile.dump(id)
    end

    test "переопределение dump/1 профиля применяется и к plain-kind на raw-пути" do
      name = SampleString.new!("Иван")

      assert Helper.dump_raw(SampleString, "Иван", PlainOverrideProfile) ==
               PlainOverrideProfile.dump(name)

      assert "str:Иван" = Helper.dump_raw(SampleString, "Иван", PlainOverrideProfile)
    end

    test "тотальность: nil, неприводимое значение и кастомный kind — как есть" do
      assert nil == Helper.dump_raw(SampleDateTime, nil, BuiltinProfile)
      assert "не дата" = Helper.dump_raw(SampleDateTime, "не дата", BuiltinProfile)
      assert "zz" = Helper.dump_raw(SampleUUID, "zz", BuiltinProfile)
      assert "Иван" = Helper.dump_raw(SampleString, "Иван", BuiltinProfile)
      assert 3 = Helper.dump_raw(SampleInteger, 3, BuiltinProfile)
      assert @uuid == Helper.dump_raw(LabelID, @uuid, BuiltinProfile)
      assert @uuid == Helper.dump_raw(DateTime, @uuid, BuiltinProfile)
    end
  end

  test "load roundtrip date across profiles" do
    date = SampleDate.new!(@date)

    assert {:ok, ^date} = InternalLike.load(SampleDate, InternalLike.dump(date))
    assert {:ok, ^date} = DateIsoProfile.load(SampleDate, DateIsoProfile.dump(date))
    assert {:ok, ^date} = InternalLike.load(SampleDate, DateIsoProfile.dump(date))
    assert {:ok, ^date} = DateIsoProfile.load(SampleDate, InternalLike.dump(date))
  end

  defp tz_offset_seconds(tz, %DateTime{} = dt) do
    {:ok, shifted} = DateTime.shift_zone(dt, tz)
    shifted.utc_offset + shifted.std_offset
  end

  test "profile rejects missing datetime_tz" do
    assert_raise CompileError, ~r/нет обязательных опций/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.CodecTest.MissingTz do
            use Core.Codec,
              uuid: :hex,
              datetime: :iso8601,
              decimal: :string
          end
        end
      )
    end
  end

  test "profile rejects unknown datetime_tz and legacy :raw" do
    assert_raise ArgumentError, ~r/неизвестная зона datetime_tz/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.CodecTest.BadTz do
            use Core.Codec,
              uuid: :hex,
              datetime: :iso8601,
              datetime_tz: "Not/AZone",
              decimal: :string
          end
        end
      )
    end

    assert_raise ArgumentError, ~r/datetime_tz: ожидается :keep/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.CodecTest.LegacyUtc do
            use Core.Codec,
              uuid: :hex,
              datetime: :iso8601,
              datetime_tz: :utc,
              decimal: :string
          end
        end
      )
    end

    assert_raise ArgumentError, ~r/неизвестное значение datetime/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.CodecTest.LegacyDatetimeRaw do
            use Core.Codec,
              uuid: :hex,
              datetime: :raw,
              datetime_tz: :keep,
              decimal: :string
          end
        end
      )
    end

    assert_raise ArgumentError, ~r/неизвестное значение date: :raw/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.CodecTest.BadDate do
            use Core.Codec,
              uuid: :hex,
              datetime: :iso8601,
              datetime_tz: :keep,
              date: :raw,
              decimal: :string
          end
        end
      )
    end

    assert_raise ArgumentError, ~r/неизвестное значение decimal/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.CodecTest.LegacyDecimalRaw do
            use Core.Codec,
              uuid: :hex,
              datetime: :iso8601,
              datetime_tz: :keep,
              decimal: :raw
          end
        end
      )
    end
  end

  test "load roundtrip prim uuid hex and full" do
    id = SampleUUID.new!(@uuid)
    assert {:ok, ^id} = BuiltinProfile.load(SampleUUID, BuiltinProfile.dump(id))
    assert {:ok, ^id} = InternalLike.load(SampleUUID, InternalLike.dump(id))
  end

  test "load is format-tolerant across profiles" do
    id = SampleUUID.new!(@uuid)
    hex = BuiltinProfile.dump(id)
    full = InternalLike.dump(id)

    assert {:ok, ^id} = InternalLike.load(SampleUUID, hex)
    assert {:ok, ^id} = BuiltinProfile.load(SampleUUID, full)
  end

  test "load string integer decimal datetime" do
    assert {:ok, %SampleString{}} = BuiltinProfile.load(SampleString, "ab")
    assert {:ok, %SampleInteger{}} = BuiltinProfile.load(SampleInteger, 3)

    price = SampleDecimal.new!(Decimal.new("10.5"))
    assert {:ok, ^price} = BuiltinProfile.load(SampleDecimal, BuiltinProfile.dump(price))
    assert {:ok, ^price} = InternalLike.load(SampleDecimal, InternalLike.dump(price))

    dt = SampleDateTime.now!()
    assert {:ok, loaded} = BuiltinProfile.load(SampleDateTime, BuiltinProfile.dump(dt))
    assert DateTime.compare(Codec.value(loaded), Codec.value(dt)) == :eq
  end

  test "load! raises on invalid" do
    assert_raise Exc, fn ->
      BuiltinProfile.load!(SampleString, "")
    end
  end

  test "module dump wins over dump_kind" do
    id = LabelID.new!(@uuid)
    assert PriorityProfile.dump(id) == "mod:550e8400e29b41d4a716446655440000"
  end

  test "dump_kind handles custom kind without module clause" do
    id = LabelID.new!(@uuid)
    assert KindOnlyProfile.dump(id) == "kind:550e8400e29b41d4a716446655440000"
  end

  test "custom kind without clause raises ArgumentError" do
    id = LabelID.new!(@uuid)

    assert_raise ArgumentError, ~r/нет правила dump для kind/, fn ->
      BuiltinProfile.dump(id)
    end
  end

  test "prim and entity fixture profiles compile" do
    assert {:module, _} = Code.ensure_loaded(Core.CodecFixture.Prim.Internal)
    assert {:module, _} = Code.ensure_loaded(Core.CodecFixture.Prim.External)
    assert {:module, _} = Code.ensure_loaded(Core.CodecFixture.Internal)
    assert {:module, _} = Code.ensure_loaded(Core.CodecFixture.External)
    assert function_exported?(Core.CodecFixture.Internal, :dump, 1)
    assert function_exported?(Core.CodecFixture.Internal, :load, 2)
    assert function_exported?(Core.CodecFixture.Internal, :load!, 2)
    assert function_exported?(Core.CodecFixture.External, :dump, 1)
  end

  test "compose dump matches base dump" do
    base = SampleUUID.new!(@uuid)
    composed = ApproverID.new!(@uuid)

    assert BuiltinProfile.dump(composed) == BuiltinProfile.dump(base)
    assert InternalLike.dump(composed) == InternalLike.dump(base)
    assert BuiltinProfile.dump(composed) == "550e8400e29b41d4a716446655440000"
    assert InternalLike.dump(composed) == @uuid
  end

  test "compose load from wire and roundtrip" do
    composed = ApproverID.new!(@uuid)
    hex = BuiltinProfile.dump(composed)
    full = InternalLike.dump(composed)

    assert {:ok, ^composed} = BuiltinProfile.load(ApproverID, hex)
    assert {:ok, ^composed} = InternalLike.load(ApproverID, full)
    assert {:ok, ^composed} = BuiltinProfile.load(ApproverID, full)
  end

  test "compose load invalid returns error; load! raises" do
    assert {:error, %Core.Error{ns: :prim}} =
             BuiltinProfile.load(ApproverID, "not-a-uuid")

    assert_raise Exc, fn -> BuiltinProfile.load!(ApproverID, "not-a-uuid") end
  end

  test "compose custom kind dump_kind and module dump priority" do
    id = WrappedLabelID.new!(@uuid)
    assert PriorityProfile.dump(id) == "mod:550e8400e29b41d4a716446655440000"
    assert KindOnlyProfile.dump(id) == "kind:550e8400e29b41d4a716446655440000"
  end
end
