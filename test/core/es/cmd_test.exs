defmodule Core.Es.CmdTest do
  use ExUnit.Case, async: true

  describe "use Core.Es.Cmd" do
    test "by и at в @enforce_keys — команда собирается" do
      cmd =
        compile(
          Valid,
          quote(do: @enforce_keys(~w(name by at)a)),
          quote(do: defstruct(@enforce_keys))
        )

      assert_raise ArgumentError, ~r/:by, :at/, fn -> struct!(cmd, name: 1) end
    end

    test "структура по полям — by и at обязательные ключи, команда собирается" do
      fields = [
        name: [prim: Core.EsFixture.Account.Name],
        by: [prim: Core.EsFixture.UserID],
        at: [prim: Core.Es.Event.At]
      ]

      cmd = compile(ByFields, nil, quote(do: use(Core.Struct, fields: unquote(fields))))

      assert_raise ArgumentError, ~r/:by, :at/, fn -> struct!(cmd, name: 1) end
    end

    test "без by или at в @enforce_keys — CompileError" do
      for {name, keys} <- [{NoBy, ~w(name at)a}, {NoAt, ~w(name by)a}] do
        assert_raise CompileError, ~r/обязан объявить \[:by, :at\] в @enforce_keys/, fn ->
          compile(
            name,
            quote(do: @enforce_keys(unquote(keys))),
            quote(do: defstruct(~w(name by at)a))
          )
        end
      end
    end

    test "by и at в defstruct без @enforce_keys — CompileError" do
      assert_raise CompileError, ~r/обязан объявить \[:by, :at\] в @enforce_keys/, fn ->
        compile(NotEnforced, nil, quote(do: defstruct(~w(by at)a)))
      end
    end

    test "структура по полям без by и с default: у at — CompileError «полями без default:»" do
      fields = [
        name: [prim: Core.EsFixture.Account.Name],
        at: [prim: Core.Es.Event.At, optional: true, default: nil]
      ]

      assert_raise CompileError, ~r/обязан объявить \[:by, :at\] полями без default:.*нет \[:by, :at\]/, fn ->
        compile(ByFieldsDefault, nil, quote(do: use(Core.Struct, fields: unquote(fields))))
      end
    end

    test "destroyable: у поля команды — CompileError с путём до поля" do
      fields = stamped(holder: [prim: Core.EsFixture.Account.Holder, destroyable: true])

      assert compile_error(OwnDestroyable, fields) ==
               "Es.Cmd: Core.Es.CmdTest.OwnDestroyable: holder: destroyable: у команды нет — " <>
                 "уничтоженное ПДн-значение не записывается"
    end

    test "destroyable: у поля вложенной entity: — CompileError с путём и сущностью" do
      fields = stamped(recipient: [entity: Core.StructFixture.Recipient])

      assert compile_error(EntityDestroyable, fields) ==
               "Es.Cmd: Core.Es.CmdTest.EntityDestroyable: recipient: phone: destroyable: " <>
                 "у сущности Core.StructFixture.Recipient в команде нет — уничтоженное ПДн-значение не записывается"
    end

    test "destroyable: у сущности внутри list: — CompileError с путём через элемент" do
      fields = stamped(recipients: [list: [entity: Core.StructFixture.Recipient]])

      assert compile_error(ListDestroyable, fields) =~
               "Es.Cmd: Core.Es.CmdTest.ListDestroyable: recipients: list: phone: destroyable: у сущности"
    end

    test "destroyable: у сущности в значении map: — CompileError с путём через значение" do
      fields = stamped(by_id: [map: [key: [type: :string], value: [entity: Core.StructFixture.Recipient]]])

      assert compile_error(MapDestroyable, fields) =~
               "Es.Cmd: Core.Es.CmdTest.MapDestroyable: by_id: map: value: phone: destroyable: у сущности"
    end

    test "events: у команды по полям — CompileError" do
      error =
        assert_raise CompileError, fn ->
          compile(
            WithEvents,
            nil,
            quote do
              use Core.Struct,
                fields: unquote(stamped([])),
                events: Core.EsFixture.Account.Event
            end
          )
        end

      assert error.description ==
               "Es.Cmd: Core.Es.CmdTest.WithEvents: events: у команды нет — события порождает decide/2 агрегата"
    end

    test "Prim personal: true без destroyable: — команда собирается" do
      fields = stamped(holder: [prim: Core.EsFixture.Account.Holder])

      cmd = compile(Personal, nil, quote(do: use(Core.Struct, fields: unquote(fields))))

      assert %{holder: nil} = struct(cmd)
    end

    test "без defstruct — CompileError" do
      assert_raise CompileError, ~r/команда — struct: нет defstruct/, fn ->
        compile(NoStruct, nil, nil)
      end
    end

    test "отклоняет опции при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es\.Cmd: неизвестные опции: \[:aggregate\]$/, fn ->
        {:ok, env} = Macro.Env.define_require(__ENV__, [], Core.Es.Cmd)
        Macro.expand(quote(do: Core.Es.Cmd.__using__(aggregate: Core.Version)), env)
      end
    end

    test "список опций выражением — «ожидается литеральный keyword»" do
      assert_raise CompileError, ~r/^Es\.Cmd: ожидается литеральный keyword, получено @opts$/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.CmdTest.AttrOpts do
              @opts []
              use Core.Es.Cmd, @opts
            end
          end
        )
      end
    end
  end

  # ---

  defp compile_error(name, fields) do
    error =
      assert_raise CompileError, fn ->
        compile(name, nil, quote(do: use(Core.Struct, fields: unquote(fields))))
      end

    error.description
  end

  defp stamped(fields), do: fields ++ [by: [prim: Core.EsFixture.UserID], at: [prim: Core.Es.Event.At]]

  defp compile(name, enforce, struct) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Cmd

          unquote(enforce)
          unquote(struct)
        end
      end
    )

    module
  end
end
