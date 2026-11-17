defmodule Core.Es.Event.PayloadPersonalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Core.Es.Personal.Destroyed
  alias Core.EsFixture.Account
  alias Core.PrimFixture

  defmodule Steps do
    @moduledoc false

    defmodule Step do
      @moduledoc false

      use Core.Struct,
        fields: [
          owner_id: [prim: Core.EventFixture.PersonID],
          recipient: [prim: Core.PrimFixture.Personal, subject: {:local, :owner_id}]
        ]
    end

    use Core.Es.Event.Payload, fields: [steps: [list: [entity: Step]]]
  end

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

    test "плагин сущности поля не объявляет — fields: неизвестная опция" do
      assert_raise CompileError, ~r/^Codec\.Plugin: неизвестные опции: \[:fields\]$/, fn ->
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

  describe "ПДн-план и защита записи" do
    test "__es_personal__/0 — места с путями и субъектами, в том числе вложенные" do
      assert Core.PersonalBrokenFixture.Event.Codec.__es_personal__() == %{
               Core.PersonalBrokenFixture.Event.ContactAdded => [
                 %{path: [:contact, :phone], subject: :aggregate_id}
               ],
               Core.PersonalBrokenFixture.Event.Named => [%{path: [:name], subject: :aggregate_id}]
             }
    end

    test "new/N отвергает уничтоженное значение на вложенном месте" do
      contact = %Core.PersonalBrokenFixture.Contact{phone: %Core.Es.Personal.Destroyed{}}

      assert_raise ArgumentError, ~r/ПДн-место contact\.phone: уничтоженное/, fn ->
        Core.PersonalBrokenFixture.Event.ContactAdded.Payload.new(contact)
      end
    end

    test "draft/1 отвергает уничтоженное значение на вложенном месте" do
      contact = %Core.PersonalBrokenFixture.Contact{phone: %Core.Es.Personal.Destroyed{}}
      payload = %Core.PersonalBrokenFixture.Event.ContactAdded.Payload{contact: contact}

      assert_raise ArgumentError, ~r/ПДн-место contact\.phone: уничтоженное/, fn ->
        Core.PersonalBrokenFixture.Event.ContactAdded.draft(payload)
      end
    end

    test "dump отвергает уничтоженное значение на вложенном месте" do
      contact = %Core.PersonalBrokenFixture.Contact{phone: %Core.Es.Personal.Destroyed{}}
      payload = %Core.PersonalBrokenFixture.Event.ContactAdded.Payload{contact: contact}

      event =
        Core.PersonalBrokenFixture.Event.ContactAdded.new(
          payload,
          Core.EventFixture.AggID.new(),
          Core.Version.new!(1),
          Core.EventFixture.ActorID.new(),
          Core.Es.Event.At.now!()
        )

      assert_raise ArgumentError, ~r/ПДн-место contact\.phone: уничтоженное/, fn ->
        Core.PersonalBrokenFixture.Event.Codec.dump(event, Core.CodecFixture.Internal)
      end
    end

    test "new/N отвергает непустое ПДн-значение при nil локальном субъекте" do
      step = %Core.Es.Event.PayloadPersonalTest.Steps.Step{
        owner_id: nil,
        recipient: PrimFixture.Personal.new!("+7 900 000-00-00")
      }

      assert_raise ArgumentError, ~r/ПДн-место steps\.each\.recipient: непустое ПДн-значение без субъекта/, fn ->
        Core.Es.Event.PayloadPersonalTest.Steps.new([step])
      end
    end
  end

  defmodule Mark do
    @moduledoc """
    Семейство вариантов без Codec-плагина в фасаде тестов: поле с `personal: true` не должно до
    него доходить.
    """

    defmodule Blob do
      @moduledoc false

      defstruct [:points]
    end

    use Core.Union,
      variants: [{Core.Es.Event.PayloadPersonalTest.Mark.Blob, "blob"}]
  end

  defmodule Marked.Payload do
    @moduledoc false

    use Core.Es.Event.Payload,
      fields: [mark: [union: Core.Es.Event.PayloadPersonalTest.Mark, personal: true]]
  end

  describe "union: у поля нагрузки" do
    test "уничтоженное значение возвращается до выбора варианта, Codec варианта не зовётся" do
      family =
        Core.EventFixture.family_ast(Core.Es.Event.PayloadPersonalTest.MarkCodec,
          Marked: Core.Es.Event.PayloadPersonalTest.Marked.Payload
        )

      {{:module, codec, _binary, _term}, _binding} =
        Code.eval_quoted(
          quote do
            unquote(family)

            defmodule Core.Es.Event.PayloadPersonalTest.MarkCodec do
              use Core.Es.Event.Codec,
                family: __MODULE__.Family,
                type: "local_mark",
                tags: %{__MODULE__.Marked => "local_mark.marked"}
            end
          end
        )

      wire = put_payload(holder_wire(), %{"mark" => %{"$pd" => nil}})
      marked = Module.concat(codec, "Marked")

      assert {:ok, %{payload: %{mark: %Destroyed{}}} = event} =
               codec.load(marked, wire, Core.CodecFixture.Internal)

      assert event.__struct__ == marked
    end
  end

  describe "CompileError" do
    test "субъект — не Prim.UUID" do
      assert_raise CompileError, ~r/^Es.Event.Payload: fields: phone: субъект name — не Prim.UUID/, fn ->
        payload(:NotUUID,
          name: [prim: Account.Name],
          phone: [prim: PrimFixture.Personal, subject: :name]
        )
      end
    end

    test "субъект — список UUID" do
      assert_raise CompileError, ~r/^Es.Event.Payload: fields: phone: субъект ids — не Prim.UUID/, fn ->
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
              use Core.Prim.UUID,
                name: "Ссылка",
                kind: :ref
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
      assert_raise CompileError,
                   ~r/^Es.Event.Payload: fields: phone: обязательное при необязательном субъекте person_id/,
                   fn ->
                     payload(:OptionalSubject,
                       person_id: [prim: Account.ID, optional: true],
                       phone: [prim: PrimFixture.Personal, subject: :person_id]
                     )
                   end
    end

    test "subject: на несуществующее поле" do
      assert_raise CompileError, ~r/^Es.Event.Payload: fields: phone: subject: :person_id — нет такого поля/, fn ->
        payload(:MissingSubject, phone: [prim: PrimFixture.Personal, subject: :person_id])
      end
    end

    test "subject: на само себя" do
      assert_raise CompileError, ~r/^Es.Event.Payload: fields: id: subject: :id — поле не бывает своим субъектом/, fn ->
        payload(:SelfSubject, id: [prim: Account.ID, subject: :id])
      end
    end

    test "субъект с subject: сам" do
      assert_raise CompileError, ~r/^Es.Event.Payload: fields: phone: субъект person_id сам объявлен с subject:/, fn ->
        payload(:SubjectOfSubject,
          person_id: [prim: Account.ID, personal: true, subject: :aggregate_id],
          phone: [prim: PrimFixture.Personal, subject: :person_id]
        )
      end
    end

    test "subject: — не атом и не nil" do
      assert_raise CompileError, ~r/: phone: subject: ожидается :aggregate_id или имя поля нагрузки/, fn ->
        payload(:StringSubject, phone: [prim: PrimFixture.Personal, subject: "aggregate_id"])
      end

      assert_raise CompileError, ~r/: phone: subject: ожидается :aggregate_id или имя поля нагрузки/, fn ->
        payload(:NilSubject, phone: [prim: PrimFixture.Personal, subject: nil])
      end
    end

    test "wire-ключ на $ — у любой нагрузки" do
      assert_raise CompileError, ~r/name: wire-ключ "\$pd" начинается с \$/, fn ->
        payload(:DollarWire, name: [prim: Account.Name, wire: "$pd"])
      end
    end

    test "subject: :aggregate_id при не-UUID aggregate_id: проверяет use Core.Es.Event" do
      assert_raise CompileError,
                   ~r/^Es.Event: payload: поле holder .* subject: :aggregate_id, а aggregate_id: .*Name — не Prim.UUID/,
                   fn ->
                     compile(
                       quote do
                         defmodule Core.Es.Event.PayloadPersonalTest.NameStream.Event do
                           use Core.Es.Event.Family,
                             aggregate: Account,
                             aggregate_id: Account.Name,
                             by: Core.EsFixture.UserID,
                             codec: Account.Event.Codec

                           @type t :: struct()
                         end

                         defmodule Core.Es.Event.PayloadPersonalTest.NameStream do
                           use Core.Es.Event,
                             family: Core.Es.Event.PayloadPersonalTest.NameStream.Event,
                             payload: Account.Event.HolderSet.Payload
                         end
                       end
                     )
                   end
    end

    test "subject: :aggregate_id при не-UUID aggregate_id: — и у Payload, вложенного в событие" do
      assert_raise CompileError,
                   ~r/^Es.Event: payload: поле holder нагрузки .*Nested\.Payload объявлено с subject: :aggregate_id/,
                   fn ->
                     compile(
                       quote do
                         defmodule Core.Es.Event.PayloadPersonalTest.NestedStream.Event do
                           use Core.Es.Event.Family,
                             aggregate: Account,
                             aggregate_id: Account.Name,
                             by: Core.EsFixture.UserID,
                             codec: Account.Event.Codec

                           @type t :: struct()
                         end

                         defmodule Core.Es.Event.PayloadPersonalTest.NestedStream.Nested do
                           defmodule Payload do
                             use Core.Es.Event.Payload,
                               fields: [holder: [prim: Account.Name, personal: true, subject: :aggregate_id]]
                           end

                           use Core.Es.Event,
                             family: Core.Es.Event.PayloadPersonalTest.NestedStream.Event,
                             payload: __MODULE__.Payload
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

  defp holder_wire, do: Jason.decode!(File.read!("test/support/fixtures/events/account/account.holder_set.json"))

  defp put_payload(wire, fields), do: Map.update!(wire, "payload", &Map.merge(&1, fields))

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
