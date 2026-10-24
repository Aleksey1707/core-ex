defmodule Core.Es.Event.TagsCaseTest do
  use ExUnit.Case, async: true

  alias Core.Es.Event.TagsCase
  alias Core.Es.Event.TagsCaseTest.Order
  alias Core.Es.Event.TagsCaseTest.Parcel

  @order %{codec: Order, type: "order", tags: ~w(order.created order.item.added)}
  @parcel %{codec: Parcel, type: "parcel", tags: ~w(parcel.registered)}

  describe "опции" do
    test "otp_app: не атом и не список — CompileError" do
      assert_raise CompileError, ~r/otp_app/, fn ->
        Code.compile_string(~s|defmodule BadOtpApp do\n use Core.Es.Event.TagsCase, otp_app: "core"\nend|)
      end
    end

    test "async: не boolean — CompileError" do
      assert_raise CompileError, ~r/async/, fn ->
        Code.compile_string(~s|defmodule BadAsync do\n use Core.Es.Event.TagsCase, otp_app: :core, async: 1\nend|)
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es\.Event\.TagsCase: неизвестные опции: \[:except_tag\]$/, fn ->
        expand_using(otp_app: :core, except_tag: %{})
      end
    end

    test "except_tags: и except_types: — литералы, проверяются при раскрытии" do
      assert {:__block__, _, _} =
               expand_using(otp_app: :core, except_tags: %{Order => ~w(created)}, except_types: [Order])

      assert_raise CompileError, ~r/^Es\.Event\.TagsCase: except_tags: ожидается map/, fn ->
        expand_using(otp_app: :core, except_tags: [:x])
      end

      assert_raise CompileError, ~r/^Es\.Event\.TagsCase: except_tags: .*Order: ожидается непустая строка/, fn ->
        expand_using(otp_app: :core, except_tags: %{Order => [:created]})
      end

      assert_raise CompileError, ~r/^Es\.Event\.TagsCase: except_types: ожидается список кодеков/, fn ->
        expand_using(otp_app: :core, except_types: %{})
      end
    end

    test "атрибут в except_tags: — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Es\.Event\.TagsCase: except_tags: ожидается литерал, получено @excepts$/, fn ->
        Code.compile_string("""
        defmodule AttrExceptTags do
          @excepts %{}
          use Core.Es.Event.TagsCase, otp_app: :core, except_tags: @excepts
        end
        """)
      end
    end
  end

  describe "codecs!/1" do
    test "теги кодека — значения tags: плюс ключи upcasts:" do
      fixture = Enum.find(TagsCase.codecs!(:core), &(&1.codec == Core.EventFixture.Event.Codec))

      assert fixture.type == "fixture"
      assert "fixture.created" in fixture.tags
      assert "fixture.opened" in fixture.tags
    end

    test "принимает список приложений" do
      assert TagsCase.codecs!([:core]) == TagsCase.codecs!(:core)
    end

    test "незагруженное приложение — ArgumentError" do
      assert_raise ArgumentError, ~r/не загружено/, fn -> TagsCase.codecs!(:no_such_app) end
    end

    test "приложение без кодеков — ArgumentError" do
      assert_raise ArgumentError, ~r/нет кодеков/, fn -> TagsCase.codecs!(:logger) end
    end
  end

  describe "check_type_format/2" do
    test "snake_case проходит" do
      assert :ok = TagsCase.check_type_format([@order, @parcel], [])
    end

    test "точка в type: — провал" do
      codec = %{@order | type: "order.line"}

      assert {:error, %{bad_type: [{Order, "order.line"}]}} = TagsCase.check_type_format([codec], [])
    end

    test "не snake_case — провал" do
      codec = %{@order | type: "OrderLine"}

      assert {:error, %{bad_type: [{Order, "OrderLine"}]}} = TagsCase.check_type_format([codec], [])
    end

    test "except_types снимает проверку с названного кодека" do
      codec = %{@order | type: "order.line"}

      assert :ok = TagsCase.check_type_format([codec], [Order])
    end
  end

  describe "check_tag_format/3" do
    test "тег с префиксом и одним и более сегментов проходит" do
      assert :ok = TagsCase.check_tag_format([@order, @parcel], %{}, [])
    end

    test "тег без префикса — провал" do
      codec = %{@order | tags: ~w(created)}

      assert {:error, %{bad_tag: [{Order, "created"}]}} = TagsCase.check_tag_format([codec], %{}, [])
    end

    test "тег ровно из type: без сегмента — провал" do
      codec = %{@order | tags: ~w(order)}

      assert {:error, %{bad_tag: [{Order, "order"}]}} = TagsCase.check_tag_format([codec], %{}, [])
    end

    test "чужой префикс — провал" do
      codec = %{@order | tags: ~w(orders.created)}

      assert {:error, %{bad_tag: [{Order, "orders.created"}]}} = TagsCase.check_tag_format([codec], %{}, [])
    end

    test "сегмент не в snake_case — провал" do
      codec = %{@order | tags: ~w(order.Created)}

      assert {:error, %{bad_tag: [{Order, "order.Created"}]}} = TagsCase.check_tag_format([codec], %{}, [])
    end

    test "кодек с невалидным type: пропускается: дефект отчитывает check_type_format/2" do
      codec = %{@order | type: "OrderLine", tags: ~w(created)}

      assert :ok = TagsCase.check_tag_format([codec], %{}, [])
    end

    test "кодек с исключённым type: проверяется: его тип принят как есть" do
      codec = %{@order | type: "order.line", tags: ~w(order.line.created created)}

      assert {:error, %{bad_tag: [{Order, "created"}]}} =
               TagsCase.check_tag_format([codec], %{}, [Order])
    end

    test "except_tags снимает проверку с названного тега названного кодека" do
      codec = %{@order | tags: ~w(created order.updated)}

      assert :ok = TagsCase.check_tag_format([codec], %{Order => ~w(created)}, [])
    end

    test "except_tags не снимает одноимённый тег другого кодека" do
      order = %{@order | tags: ~w(created)}
      parcel = %{@parcel | tags: ~w(created)}

      assert {:error, %{bad_tag: [{Parcel, "created"}]}} =
               TagsCase.check_tag_format([order, parcel], %{Order => ~w(created)}, [])
    end
  end

  describe "check_tag_uniqueness/1" do
    test "теги разных кодеков не пересекаются" do
      assert :ok = TagsCase.check_tag_uniqueness([@order, @parcel])
    end

    test "тег двух кодеков — провал с обоими" do
      parcel = %{@parcel | tags: ~w(order.created)}

      assert {:error, %{duplicate_tags: [{"order.created", [Order, Parcel]}]}} =
               TagsCase.check_tag_uniqueness([@order, parcel])
    end

    test "ключ upcasts: чужого кодека считается тегом" do
      order = %{@order | tags: ~w(order.created parcel.registered)}

      assert {:error, %{duplicate_tags: [{"parcel.registered", [Order, Parcel]}]}} =
               TagsCase.check_tag_uniqueness([order, @parcel])
    end
  end

  describe "check_type_uniqueness/1" do
    test "типы разных кодеков не пересекаются" do
      assert :ok = TagsCase.check_type_uniqueness([@order, @parcel])
    end

    test "тип двух кодеков — провал с обоими" do
      parcel = %{@parcel | type: "order"}

      assert {:error, %{duplicate_types: [{"order", [Order, Parcel]}]}} =
               TagsCase.check_type_uniqueness([@order, parcel])
    end
  end

  # ---

  defp expand_using(opts) do
    {:ok, env} = Macro.Env.define_require(__ENV__, [], TagsCase)
    Macro.expand(quote(do: Core.Es.Event.TagsCase.__using__(unquote(Macro.escape(opts)))), env)
  end
end
