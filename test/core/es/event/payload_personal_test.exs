defmodule Core.Es.Event.PayloadPersonalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Core.EsFixture.Account
  alias Core.PrimFixture

  describe "subject: у поля нагрузки" do
    test "спека поля в __es_payload_fields__/0 несёт subject:" do
      assert [
               %Core.Codec.Field{
                 name: :holder,
                 subject: :aggregate_id
               }
             ] =
               Account.Event.HolderSet.Payload.__es_payload_fields__()
    end

    test "поле той же нагрузки — субъект" do
      assert [
               %Core.Codec.Field{
                 name: :person_id,
                 optional?: true,
                 subject: nil
               },
               %Core.Codec.Field{
                 name: :contact,
                 optional?: true,
                 subject: :person_id
               },
               %Core.Codec.Field{
                 name: :note,
                 optional?: false,
                 subject: :aggregate_id
               }
             ] = Core.EventFixture.Event.ContactSet.Payload.__es_payload_fields__()
    end

    test "плагин сущности subject: не принимает" do
      assert_raise CompileError, ~r/неизвестные ключи \[:subject\]/, fn ->
        compile(
          quote do
            defmodule Core.Es.Event.PayloadPersonalTest.PluginSubject do
              defstruct [:phone]

              use Core.Codec.Plugin,
                fields: [{__MODULE__, phone: [prim: PrimFixture.Personal, subject: :aggregate_id]}]
            end
          end
        )
      end
    end
  end

  describe "CompileError" do
    test "персональный Prim на прямом поле без subject:" do
      assert_raise CompileError, ~r/поле phone: персональный Prim .*Personal без subject:/, fn ->
        payload(:Bare, phone: [prim: PrimFixture.Personal])
      end
    end

    test "персональный Prim элементом list: без subject:" do
      assert_raise CompileError, ~r/поле phones: персональный Prim .*Personal без subject:/, fn ->
        payload(:BareList, phones: [list: [prim: PrimFixture.Personal]])
      end
    end

    test "персональный композит без subject:" do
      assert_raise CompileError, ~r/поле phone: персональный Prim .*PersonalRef без subject:/, fn ->
        payload(:BareRef, phone: [prim: PrimFixture.PersonalRef])
      end
    end

    test "субъект — не Prim.UUID" do
      assert_raise CompileError, ~r/поле phone: субъект name — не Prim.UUID/, fn ->
        payload(:NotUUID,
          name: [prim: Account.Name],
          phone: [prim: PrimFixture.Personal, subject: :name]
        )
      end
    end

    test "субъект — список UUID" do
      assert_raise CompileError, ~r/поле phone: субъект ids — не Prim.UUID/, fn ->
        payload(:ListUUID,
          ids: [list: [prim: Account.ID]],
          phone: [prim: PrimFixture.Personal, subject: :ids]
        )
      end
    end

    test "Prim.Compose над UUID — субъект" do
      # `Inspect` нагрузки с `subject:` выводится после консолидации протоколов — предупреждение.
      capture_io(:stderr, fn ->
        payload(:ComposedUUID,
          ref: [prim: PrimFixture.SubjectRef],
          phone: [prim: PrimFixture.Personal, subject: :ref]
        )
      end)
    end

    test "UUID-Prim со своим kind: — субъект" do
      capture_io(:stderr, fn ->
        compile(
          quote do
            defmodule Core.Es.Event.PayloadPersonalTest.RefID do
              use Core.Prim.UUID, name: "Ссылка", kind: :ref
            end
          end
        )

        payload(:CustomKindUUID,
          ref: [prim: Core.Es.Event.PayloadPersonalTest.RefID],
          phone: [prim: PrimFixture.Personal, subject: :ref]
        )
      end)
    end

    test "обязательное ПДн-поле при необязательном субъекте" do
      assert_raise CompileError, ~r/поле phone: обязательное при необязательном субъекте person_id/, fn ->
        payload(:OptionalSubject,
          person_id: [prim: Account.ID, optional: true],
          phone: [prim: PrimFixture.Personal, subject: :person_id]
        )
      end
    end

    test "subject: на несуществующее поле" do
      assert_raise CompileError, ~r/поле phone: subject: :person_id — нет такого поля/, fn ->
        payload(:MissingSubject, phone: [prim: PrimFixture.Personal, subject: :person_id])
      end
    end

    test "subject: на само себя" do
      assert_raise CompileError, ~r/поле id: subject: :id — поле не бывает своим субъектом/, fn ->
        payload(:SelfSubject, id: [prim: Account.ID, subject: :id])
      end
    end

    test "субъект с subject: сам" do
      assert_raise CompileError, ~r/поле phone: субъект person_id сам объявлен с subject:/, fn ->
        payload(:SubjectOfSubject,
          person_id: [prim: Account.ID, subject: :aggregate_id],
          phone: [prim: PrimFixture.Personal, subject: :person_id]
        )
      end
    end

    test "subject: — не атом и не nil" do
      assert_raise CompileError, ~r/поле phone: subject: атом/, fn ->
        payload(:StringSubject, phone: [prim: PrimFixture.Personal, subject: "aggregate_id"])
      end

      assert_raise CompileError, ~r/поле phone: subject: атом/, fn ->
        payload(:NilSubject, phone: [prim: PrimFixture.Personal, subject: nil])
      end
    end

    test "wire-ключ на $ — у любой нагрузки" do
      assert_raise CompileError, ~r/поле name: wire-ключ "\$pd" начинается с \$/, fn ->
        payload(:DollarWire, name: [prim: Account.Name, wire: "$pd"])
      end
    end

    test "subject: :aggregate_id при не-UUID aggregate_id: проверяет use Core.Es.Event" do
      assert_raise CompileError,
                   ~r/Es.Event: поле holder нагрузки .* subject: :aggregate_id, а aggregate_id: .*Name — не Prim.UUID/,
                   fn ->
                     compile(
                       quote do
                         defmodule Core.Es.Event.PayloadPersonalTest.NameStream do
                           use Core.Es.Event,
                             aggregate_id: Account.Name,
                             by: Core.EsFixture.UserID,
                             payload: Account.Event.HolderSet.Payload
                         end
                       end
                     )
                   end
    end
  end

  # ---

  defp payload(name, fields) do
    module = Module.concat(__MODULE__, name)

    compile(
      quote do
        defmodule unquote(module) do
          use Core.Es.Event.Payload, fields: unquote(fields)
        end
      end
    )
  end

  defp compile(quoted) do
    Code.eval_quoted(
      quote do
        alias Core.EsFixture.Account
        alias Core.PrimFixture
        unquote(quoted)
      end
    )
  end
end
