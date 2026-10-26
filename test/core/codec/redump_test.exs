defmodule Core.Codec.RedumpTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Redump
  alias Core.Prim

  defmodule Profile do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: "Etc/UTC",
      date: :iso8601,
      decimal: :string
  end

  defmodule ID do
    use Prim.UUID, name: "Идентификатор", version: 4
  end

  defmodule At do
    use Prim.DateTime, name: "Момент"
  end

  defmodule Weight do
    use Prim.Decimal, name: "Вес", min: 0
  end

  defmodule Day do
    use Prim.Date, name: "Дата"
  end

  defmodule Label do
    use Prim.UUID, name: "Метка", version: 4, kind: :label
  end

  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @hex "550e8400e29b41d4a716446655440000"

  describe "run/3 — {:prim, mod}" do
    test "переводит значение в формат Prim" do
      assert Redump.run(@uuid, {:prim, ID}, Profile) == @hex
      assert Redump.run(Decimal.new("10.5"), {:prim, Weight}, Profile) == "10.5"
      assert Redump.run(~D[2024-06-01], {:prim, Day}, Profile) == "2024-06-01"
    end

    test "nil и неприводимое значение проходят как есть" do
      assert nil == Redump.run(nil, {:prim, ID}, Profile)
      assert "zz" = Redump.run("zz", {:prim, ID}, Profile)
    end
  end

  describe "run/3 — {:map, fields}" do
    test "заменяет объявленные поля, не описанные не трогает" do
      map = %{id: @uuid, name: "Иван", at: ~U[2024-06-01 12:00:00Z]}
      spec = {:map, %{id: {:prim, ID}, at: {:prim, At}}}

      assert %{id: @hex, name: "Иван", at: "2024-06-01T12:00:00Z"} =
               Redump.run(map, spec, Profile)
    end

    test "string-ключи сохраняют вид ключа" do
      map = %{"id" => @uuid, "name" => "Иван"}

      assert %{"id" => @hex, "name" => "Иван"} =
               Redump.run(map, {:map, %{id: {:prim, ID}}}, Profile)
    end

    test "отсутствующее поле не появляется" do
      assert %{"name" => "Иван"} =
               Redump.run(%{"name" => "Иван"}, {:map, %{id: {:prim, ID}}}, Profile)
    end

    test "не-map проходит как есть" do
      assert "строка" = Redump.run("строка", {:map, %{id: {:prim, ID}}}, Profile)
    end
  end

  describe "run/3 — {:list, spec}" do
    test "применяет спеку к каждому элементу" do
      list = [%{"id" => @uuid}, %{"id" => @uuid}]
      spec = {:list, {:map, %{id: {:prim, ID}}}}

      assert [%{"id" => @hex}, %{"id" => @hex}] = Redump.run(list, spec, Profile)
    end

    test "не-список проходит как есть" do
      assert %{} == Redump.run(%{}, {:list, {:prim, ID}}, Profile)
    end
  end

  describe "run/3 — {:set, spec}" do
    test "переводит элементы и пишет их в каноническом порядке без повторов" do
      list = [~U[2024-06-02 00:00:00Z], ~U[2024-06-01 00:00:00Z], ~U[2024-06-02 00:00:00Z]]

      assert Redump.run(list, {:set, {:prim, At}}, Profile) == ["2024-06-01T00:00:00Z", "2024-06-02T00:00:00Z"]
    end

    test "не-список проходит как есть" do
      assert %{} == Redump.run(%{}, {:set, {:prim, ID}}, Profile)
    end
  end

  describe "run/3 — {:dict, key, value}" do
    test "переводит ключ и значение, nil — как есть" do
      dict = %{@uuid => Decimal.new("10.5")}

      assert Redump.run(dict, {:dict, {:prim, ID}, {:prim, Weight}}, Profile) == %{@hex => "10.5"}
      assert Redump.run(dict, {:dict, nil, {:prim, Weight}}, Profile) == %{@uuid => "10.5"}
      assert Redump.run(dict, {:dict, {:prim, ID}, nil}, Profile) == %{@hex => Decimal.new("10.5")}
    end

    test "значение — любая спека" do
      dict = %{"a" => [%{"id" => @uuid}]}

      assert Redump.run(dict, {:dict, nil, {:list, {:map, %{id: {:prim, ID}}}}}, Profile) ==
               %{"a" => [%{"id" => @hex}]}
    end

    test "не-map проходит как есть" do
      assert [] == Redump.run([], {:dict, {:prim, ID}, nil}, Profile)
    end
  end

  describe "run/3 — {:tagged, by_tag}" do
    setup do
      %{
        spec:
          {:tagged,
           %{
             "weighting" => {:map, %{value: {:prim, Weight}}},
             "dating" => {:map, %{day: {:prim, Day}}}
           }}
      }
    end

    test "выбирает спеку по тегу", %{spec: spec} do
      payload = %{"type" => "weighting", "fields" => %{"value" => Decimal.new("3.5")}}

      assert %{"type" => "weighting", "fields" => %{"value" => "3.5"}} =
               Redump.run(payload, spec, Profile)
    end

    test "atom-ключи envelope тоже разбираются", %{spec: spec} do
      payload = %{type: "dating", fields: %{day: ~D[2024-06-01]}}

      assert %{type: "dating", fields: %{day: "2024-06-01"}} = Redump.run(payload, spec, Profile)
    end

    test "неизвестный тег проходит как есть", %{spec: spec} do
      payload = %{"type" => "removed_step", "fields" => %{"value" => Decimal.new("3.5")}}

      assert ^payload = Redump.run(payload, spec, Profile)
    end

    test "нет тега или нагрузки — как есть", %{spec: spec} do
      assert %{"fields" => %{}} == Redump.run(%{"fields" => %{}}, spec, Profile)

      assert %{"type" => "weighting", "fields" => nil} ==
               Redump.run(%{"type" => "weighting", "fields" => nil}, spec, Profile)
    end
  end

  test "вложенность списка в map под tagged" do
    spec =
      {:map,
       %{
         steps:
           {:list,
            {:map,
             %{
               at: {:prim, At},
               payload: {:tagged, %{"w" => {:map, %{value: {:prim, Weight}}}}}
             }}}
       }}

    value = %{
      "steps" => [
        %{
          "at" => "2024-06-01T12:00:00Z",
          "payload" => %{"type" => "w", "fields" => %{"value" => 3.5}}
        }
      ]
    }

    assert %{
             "steps" => [
               %{
                 "at" => "2024-06-01T12:00:00Z",
                 "payload" => %{"type" => "w", "fields" => %{"value" => "3.5"}}
               }
             ]
           } = Redump.run(value, spec, Profile)
  end

  describe "run/3 — {:codec, mod}" do
    defmodule Stub do
      def __codec_redump__(ID), do: {:prim, ID}
      def __codec_redump__(Tree), do: {:map, %{id: {:prim, ID}, next: {:codec, Tree}}}

      def dump(prim), do: Profile.dump(prim)
    end

    test "берёт спеку у фасада и переводит по ней" do
      assert Redump.run(@uuid, {:codec, ID}, Stub) == @hex
    end

    test "рекурсивная ссылка разворачивается по данным" do
      value = %{"id" => @uuid, "next" => %{"id" => @uuid, "next" => nil}}

      assert %{"id" => @hex, "next" => %{"id" => @hex, "next" => nil}} = Redump.run(value, {:codec, Tree}, Stub)
    end

    test "nil — как есть, без обращения к фасаду" do
      assert nil == Redump.run(nil, {:codec, Unknown}, Stub)
    end
  end

  describe "run/3 — :sensitive" do
    test "ключ удаляется из результата" do
      spec = {:map, %{id: {:prim, ID}, token: :sensitive}}

      assert Redump.run(%{"id" => @uuid, "token" => "s"}, spec, Profile) == %{"id" => @hex}
      assert Redump.run(%{token: "s"}, spec, Profile) == %{}
    end

    test "ключа нет — ничего не делается" do
      assert Redump.run(%{"name" => "Иван"}, {:map, %{token: :sensitive}}, Profile) == %{"name" => "Иван"}
    end
  end

  describe "validate!/1 — {:codec, mod} и :sensitive" do
    test "принимает {:codec, M} без проверки существования и :sensitive полем map" do
      assert Redump.validate!({:codec, Missing.Type}) == {:codec, Missing.Type}

      spec = {:map, %{token: :sensitive, "wire-key": {:list, {:codec, Missing.Type}}}}

      assert Redump.validate!(spec) == spec
    end

    test "отвергает :sensitive вне значения поля map" do
      for spec <- [:sensitive, {:list, :sensitive}, {:tagged, %{"t" => :sensitive}}] do
        assert_raise ArgumentError, ~r/только значением поля/, fn -> Redump.validate!(spec) end
      end
    end

    test "отвергает {:codec, _} не с модулем" do
      assert_raise ArgumentError, ~r/неверная спека Redump/, fn -> Redump.validate!({:codec, "Type"}) end
    end
  end

  describe "validate!/1" do
    test "принимает все четыре формы спеки" do
      assert Redump.validate!({:prim, At}) == {:prim, At}
      assert Redump.validate!({:list, {:prim, At}}) == {:list, {:prim, At}}
      assert Redump.validate!({:map, %{at: {:prim, At}}}) == {:map, %{at: {:prim, At}}}

      tagged = {:tagged, %{"w" => {:map, %{value: {:prim, Weight}}}}}

      assert Redump.validate!(tagged) == tagged
    end

    test "множество и словарь: ключ — nil или {:prim, _}, значение — nil или спека" do
      assert Redump.validate!({:set, {:prim, At}}) == {:set, {:prim, At}}
      assert Redump.validate!({:dict, {:prim, ID}, nil}) == {:dict, {:prim, ID}, nil}
      assert Redump.validate!({:dict, nil, {:list, {:prim, At}}}) == {:dict, nil, {:list, {:prim, At}}}

      assert_raise ArgumentError, ~r/требует Prim-модуль/, fn -> Redump.validate!({:set, {:prim, Enum}}) end
      assert_raise ArgumentError, ~r/требует Prim-модуль/, fn -> Redump.validate!({:dict, nil, {:prim, Enum}}) end

      assert_raise ArgumentError, ~r/неверный ключ спеки \{:dict, _, _\}: .*; ожидается nil или \{:prim, Mod\}/, fn ->
        Redump.validate!({:dict, {:codec, ID}, nil})
      end

      assert_raise ArgumentError, ~r/только значением поля/, fn -> Redump.validate!({:dict, nil, :sensitive}) end
    end

    test "форма без форматируемых полей допустима" do
      assert Redump.validate!({:map, %{}}) == {:map, %{}}
      assert Redump.validate!({:tagged, %{}}) == {:tagged, %{}}
    end

    test "проверяет вложенные спеки" do
      assert_raise ArgumentError, ~r/требует Prim-модуль/, fn ->
        Redump.validate!({:list, {:map, %{at: {:prim, Enum}}}})
      end
    end

    test "отвергает не-Prim модуль" do
      assert_raise ArgumentError, ~r/требует Prim-модуль/, fn ->
        Redump.validate!({:prim, Enum})
      end
    end

    test "отвергает Prim, значение которого не привести из wire" do
      assert_raise ArgumentError, ~r/не приводится из wire-значения/, fn ->
        Redump.validate!({:prim, Label})
      end
    end

    test "принимает personal-Prim и переводит его значение" do
      spec = Redump.validate!({:map, %{phone: {:prim, Core.PrimFixture.Personal}}})

      assert Redump.run(%{"phone" => "+79991234567"}, spec, Profile) == %{"phone" => "+79991234567"}
    end

    test "отвергает Prim с personal и sensitive" do
      assert_raise ArgumentError, ~r/объявлен sensitive/, fn ->
        Redump.validate!({:map, %{document: {:prim, Core.PrimFixture.PersonalSensitive}}})
      end
    end

    test "отвергает sensitive-Prim — как и Core.View" do
      assert_raise ArgumentError, ~r/объявлен sensitive/, fn ->
        Redump.validate!({:map, %{token: {:prim, Core.PrimFixture.Sensitive}}})
      end
    end

    test "отвергает нестроковый тег и неатомарный ключ поля" do
      assert_raise ArgumentError, ~r/должен быть атомом/, fn ->
        Redump.validate!({:map, %{"at" => {:prim, At}}})
      end

      assert_raise ArgumentError, ~r/должен быть строкой/, fn ->
        Redump.validate!({:tagged, %{step: {:map, %{}}}})
      end
    end

    test "отвергает неизвестную форму" do
      assert_raise ArgumentError, ~r/неверная спека Redump/, fn ->
        Redump.validate!({:enum, At})
      end

      assert_raise ArgumentError, ~r/неверная спека Redump/, fn -> Redump.validate!(At) end
    end
  end
end
