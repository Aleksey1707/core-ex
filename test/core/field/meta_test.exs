defmodule Core.Field.MetaTest do
  use ExUnit.Case, async: true

  alias Core.Field.Meta

  @roles ~w(struct payload labels union)a

  describe "реестр" do
    test "обработчик на ключ в порядке объявления" do
      assert Enum.map(Meta.registry(), & &1.key()) == ~w(optional wire default personal subject)a
    end

    test "fetch! находит обработчик по ключу" do
      assert Meta.fetch!(:personal) == Core.Field.Meta.Personal
      assert_raise ArgumentError, fn -> Meta.fetch!(:destroyable) end
    end

    test "ключи реестра" do
      assert Meta.keys() == ~w(optional wire default personal subject)a
    end

    test "обработчик реализует все колбэки поведения" do
      callbacks = Core.Field.Meta.behaviour_info(:callbacks)

      assert length(callbacks) == 7

      for handler <- Meta.registry(), {name, arity} <- callbacks do
        assert Core.Helper.Module.exports?(handler, name, arity),
               "#{inspect(handler)} не реализует #{name}/#{arity}"
      end
    end
  end

  describe "матрица ролей" do
    @matrix %{
      optional: ~w(struct payload labels)a,
      wire: ~w(struct payload labels)a,
      default: ~w(struct)a,
      personal: ~w(struct payload labels)a,
      subject: ~w(struct payload)a
    }

    test "каждый ключ допустим ровно в своих ролях" do
      for {key, allowed} <- @matrix, role <- @roles do
        assert Meta.allowed?(key, role) == role in allowed,
               "#{key} в роли #{role}: ожидалось #{role in allowed}"
      end
    end

    test "у семейства вариантов ключей поля нет" do
      for key <- Meta.keys(), do: refute(Meta.allowed?(key, :union))
    end

    test "у View нет метаданных: их проверяет его парсер" do
      for key <- Meta.keys(), do: refute(Meta.allowed?(key, :view))
    end
  end

  describe "нормализация значений" do
    test "personal: — boolean" do
      assert Meta.fetch!(:personal).normalize!(true, ctx()) == true
      assert Meta.fetch!(:personal).normalize!(nil, ctx()) == nil

      assert_raise CompileError, ~r/^W: a: personal: ожидается boolean, получено :yes$/, fn ->
        Meta.fetch!(:personal).normalize!(:yes, ctx())
      end
    end

    test "subject: — адрес субъекта" do
      assert Meta.fetch!(:subject).normalize!(nil, ctx()) == nil
      assert Meta.fetch!(:subject).normalize!(:aggregate_id, ctx()) == :aggregate_id
      assert Meta.fetch!(:subject).normalize!({:payload, :a}, ctx()) == {:payload, :a}
      assert Meta.fetch!(:subject).normalize!({:local, :a}, ctx()) == {:local, :a}
      assert Meta.fetch!(:subject).normalize!(:a, %{ctx() | role: :payload}) == {:payload, :a}
      assert Meta.fetch!(:subject).normalize!(:a, %{ctx() | role: :struct}) == {:local, :a}

      assert_raise CompileError, ~r/^W: a: subject: ожидается/, fn ->
        Meta.fetch!(:subject).normalize!({:other, :a}, ctx())
      end
    end

    test "default: — уничтоженное значение не значение по умолчанию" do
      default = Meta.fetch!(:default)

      assert default.normalize!(:none, ctx()) == :none
      assert default.normalize!({:default, 1}, ctx()) == {:default, 1}

      assert_raise CompileError, ~r/^W: a: default: %Core.Es.Personal.Destroyed\{\} значением по умолчанию/, fn ->
        default.normalize!({:default, %Core.Es.Personal.Destroyed{}}, ctx())
      end
    end
  end

  describe "вопросы по полям" do
    test "read_type — уничтоженное значение на ПДн-месте" do
      %{holder: place, meta: plain} =
        fields(holder: [prim: Core.PrimFixture.Personal], meta: [prim: Core.StructFixture.Name])

      assert Meta.read_type(place, %{}) == {:union, quote(do: Core.Es.Personal.Destroyed.t())}
      assert Meta.read_type(plain, %{}) == :none
    end

    test "personal? — место целиком, а не вложенное" do
      %{holder: place, tags: nested, meta: plain} =
        fields(
          holder: [prim: Core.PrimFixture.Personal],
          tags: [list: [prim: Core.PrimFixture.Personal]],
          meta: [prim: Core.StructFixture.Name]
        )

      assert Meta.personal?(place, %{})
      refute Meta.personal?(nested, %{})
      refute Meta.personal?(plain, %{})
    end

    test "inspect_hidden — только целые ПДн-места верхнего уровня" do
      declared =
        fields(
          holder: [prim: Core.PrimFixture.Personal],
          secret: [prim: Core.PrimFixture.Personal],
          tags: [list: [prim: Core.PrimFixture.Personal]],
          meta: [prim: Core.StructFixture.Name]
        )

      assert Meta.inspect_hidden(Map.values(declared), %{}) == [:holder, :secret]
    end

    test "write_reject? и plan — обработчики ничего не добавляют" do
      %{holder: place} = fields(holder: [prim: Core.PrimFixture.Personal])

      assert Meta.write_reject?(place, %{}) == nil
      assert Meta.plan([:holder], place, %{}) == []
    end
  end

  defp fields(spec), do: Map.new(Core.Field.declare!(spec, :struct, "S"), &{&1.name, &1})

  defp ctx, do: %{role: :payload, name: :a, where: "W: a", spec: {:prim, Core.StructFixture.Name}}
end
