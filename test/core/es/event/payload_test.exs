defmodule Core.Es.Event.PayloadTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Error
  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Event
  alias Core.EsFixture.UserID
  alias Core.Version

  defmodule Status do
    use Core.Enum,
      name: "Статус",
      values: ~w(new done)a
  end

  defmodule Wide do
    use Core.Es.Event.Payload,
      fields: [
        name: [prim: Account.Name],
        note: [prim: Account.Name, optional: true],
        status: [enum: Status],
        tags: [list: [prim: Account.Name]],
        count: [type: :non_neg_integer, wire: "qty"]
      ]
  end

  @at ~U[2026-09-14 01:25:49Z]

  describe "use Core.Es.Event.Payload" do
    test "new/N — поля позиционно, в порядке объявления" do
      name = Account.Name.new!("Отгрузка")

      assert Wide.new(name, nil, :new, [name], 2) ==
               %Wide{name: name, note: nil, status: :new, tags: [name], count: 2}
    end

    test "голова new/N проверяет вид каждого поля" do
      name = Account.Name.new!("Отгрузка")

      assert_raise FunctionClauseError, fn -> Wide.new("Отгрузка", nil, :new, [], 2) end
      assert_raise FunctionClauseError, fn -> Wide.new(name, "у окна", :new, [], 2) end
      assert_raise FunctionClauseError, fn -> Wide.new(name, nil, "new", [], 2) end
      assert_raise FunctionClauseError, fn -> Wide.new(name, nil, :new, nil, 2) end
      assert_raise FunctionClauseError, fn -> Wide.new(name, nil, :new, [], -1) end
    end

    test "обязательны все поля, кроме optional:" do
      assert_raise ArgumentError, ~r/\[:name, :status, :tags, :count\]/, fn ->
        Code.eval_string("%Core.Es.Event.PayloadTest.Wide{}")
      end
    end

    test "default: — CompileError" do
      assert_raise CompileError, ~r/Es.Event.Payload .*Defaulted: fields: default: у нагрузки события нет/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.PayloadTest.Defaulted do
              use Core.Es.Event.Payload,
                fields: [name: [prim: Core.EsFixture.Account.Name, default: "без имени"]]
            end
          end
        )
      end
    end

    test "ошибка спеки называет нагрузку и поле" do
      assert_raise CompileError, ~r/Es.Event.Payload .*NotPrim: fields, поле name: .*Status не Prim/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.PayloadTest.NotPrim do
              use Core.Es.Event.Payload, fields: [name: [prim: Core.Es.Event.PayloadTest.Status]]
            end
          end
        )
      end
    end

    test "в фасаде не регистрируется" do
      assert_raise ArgumentError, ~r/нет codec-плагина/, fn ->
        InCodec.load(Event.Renamed.Payload, %{"name" => "Отгрузка"})
      end
    end
  end

  describe "Event.Codec: нагрузка по полям" do
    test "dump/load через фасад — round-trip" do
      renamed = event(Event.Renamed, Event.Renamed.Payload.new(Account.Name.new!("Отгрузка")))

      assert InCodec.dump(renamed)["payload"] == %{"name" => "Отгрузка"}
      assert InCodec.load(Event.Renamed, InCodec.dump(renamed)) == {:ok, renamed}

      wire = Jason.decode!(Jason.encode!(InCodec.dump(renamed)))

      assert InCodec.load(Account.Event, wire) == {:ok, renamed}
    end

    test "ошибка поля нагрузки — ошибка load" do
      wire = InCodec.dump(event(Event.Renamed, Event.Renamed.Payload.new(Account.Name.new!("Отгрузка"))))

      assert {:error, %Error{}} = InCodec.load(Event.Renamed, %{wire | "payload" => %{"name" => ""}})
    end

    test "кодек только с выводимыми нагрузками собирается без ручных клауз и предупреждений" do
      {{{:module, mod, _, _}, _}, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.eval_quoted(
            quote do
              defmodule Core.Es.Event.PayloadTest.DerivedOnly do
                use Core.Es.Event.Codec,
                  event: Core.EsFixture.Account.Event,
                  type: "derived_only",
                  tags: %{Core.EsFixture.Account.Event.Renamed => "derived_only.renamed"}
              end
            end
          )
        end)

      assert diagnostics == []

      renamed = event(Event.Renamed, Event.Renamed.Payload.new(Account.Name.new!("Отгрузка")))

      assert mod.dump(renamed, InCodec)["payload"] == %{"name" => "Отгрузка"}
      assert mod.load(Event.Renamed, mod.dump(renamed, InCodec), InCodec) == {:ok, renamed}
    end
  end

  describe "declared_fields/1" do
    test "поля спеки нагрузки, которая ещё собирается; модуль без use — nil" do
      defmodule DeclaredFields do
        use Core.Es.Event.Payload, fields: [name: [prim: Account.Name]]

        @declared Core.Es.Event.Payload.declared_fields(__MODULE__)

        def declared, do: @declared
      end

      defmodule UndeclaredFields do
        @declared Core.Es.Event.Payload.declared_fields(__MODULE__)

        def declared, do: @declared
      end

      assert [%Core.Codec.Field{name: :name, spec: {:prim, Account.Name}}] = DeclaredFields.declared()
      assert UndeclaredFields.declared() == nil
    end
  end

  defp event(mod, payload) do
    mod.new(payload, Account.ID.new(), Version.new!(3), UserID.new(), Core.Es.Event.At.new!(@at))
  end
end
