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

  describe "validate!/1" do
    test "принимает все четыре формы спеки" do
      assert Redump.validate!({:prim, At}) == {:prim, At}
      assert Redump.validate!({:list, {:prim, At}}) == {:list, {:prim, At}}
      assert Redump.validate!({:map, %{at: {:prim, At}}}) == {:map, %{at: {:prim, At}}}

      tagged = {:tagged, %{"w" => {:map, %{value: {:prim, Weight}}}}}

      assert Redump.validate!(tagged) == tagged
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
