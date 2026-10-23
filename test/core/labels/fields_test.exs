defmodule Core.Labels.FieldsTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Field
  alias Core.Labels.Fields
  alias Core.LabelsFixture.Address
  alias Core.LabelsFixture.Event.Linked
  alias Core.LabelsFixture.Event.NameChanged
  alias Core.LabelsFixture.Event.OriginChanged
  alias Core.LabelsFixture.Event.Shipped
  alias Core.LabelsFixture.Event.Tagged
  alias Core.LabelsFixture.Event.Updated
  alias Core.LabelsFixture.Name

  test "specs/1 — видимые поля в порядке спеки нагрузки" do
    assert Keyword.keys(Fields.specs(Updated.Payload)) == ~w(name count amount day moment note urgent rank)a
    assert Keyword.fetch!(Fields.specs(Updated.Payload), :name) == {:prim, Name}
  end

  test "specs/1 — спека fields: в порядке объявления, без скрытых полей" do
    assert Fields.specs(Address) == [city: {:prim, Name}, zip: {:type, :string}]
    assert Keyword.keys(Fields.specs(Tagged.Payload)) == ~w(origin tags count)a
  end

  describe "labelled?/1" do
    test "struct с решением по полям — да; struct без него, не struct и не модуль — нет" do
      assert Fields.labelled?(Address)
      assert Fields.labelled?(NameChanged.Payload)
      refute Fields.labelled?(URI)
      refute Fields.labelled?(Name)
      refute Fields.labelled?(Core.LabelsFixture.Texts)
      refute Fields.labelled?(Core.LabelsFixture.Missing)
    end
  end

  describe "visible/1" do
    test "видимые поля в порядке спеки, без скрытых" do
      assert Fields.visible(Address) == [city: {:prim, Name}, zip: {:type, :string}]
    end

    test "struct изменения — old_value / new_value со спекой значения" do
      assert Fields.visible(NameChanged.Payload) == [old_value: {:prim, Name}, new_value: {:prim, Name}]

      assert [old_value: {:text, fun}, new_value: {:text, fun}] = Fields.visible(OriginChanged.Payload)
      assert fun == (&Core.LabelsFixture.Texts.origin/1)
    end
  end

  describe "labels/1" do
    test "решение по каждому полю, у изменения — пусто" do
      assert Fields.labels(Address) == [city: "Город", zip: "Индекс", checksum: :hidden]
      assert Fields.labels(NameChanged.Payload) == []
    end
  end

  describe "paths/1" do
    test "поля типа и вложенных struct'ов в порядке объявления; элемент списка — под путём списка" do
      assert Fields.paths(Shipped.Payload) == [
               {[:address], "Адрес"},
               {[:address, :city], "Город"},
               {[:address, :zip], "Индекс"},
               {[:backup], "Запасной адрес"},
               {[:backup, :city], "Город"},
               {[:backup, :zip], "Индекс"},
               {[:lines], "Позиции"},
               {[:lines, :title], "Наименование"},
               {[:lines, :count], "Количество"},
               {[:counts], "Счётчики"},
               {[:shape], "Фигура"},
               {[:title], "Заголовок"}
             ]
    end

    test "скрытое поле путей не даёт; text: — подпись поля" do
      assert Fields.paths(Tagged.Payload) == [{[:origin], "Источник"}, {[:tags], "Метки"}, {[:count], "Количество"}]
    end

    test "map'а с id в ключах — подпись поля" do
      assert {[:limits], "Лимиты"} in Fields.paths(Linked.Payload)
    end
  end

  describe "declare!/3 — разбор по объявлению модуля" do
    @where "Labels.Fields X"

    test "labels: у нагрузки — спека видимых полей из нагрузки" do
      payload = Field.normalize!([name: [prim: Name], note: [type: :string]], :payload, "нагрузка")

      assert Fields.declare!({:payload, payload}, [labels: [name: "Название", note: :hidden]], @where) == %{
               specs: [name: {:prim, Name}, note: {:type, :string}],
               fields: [name: "Название", note: :hidden],
               change: nil
             }
    end

    test "fields: у struct'а — спека видимых полей из fields:" do
      declared = Fields.declare!(:struct, [fields: [city: [prim: Name]], labels: [city: "Город"]], @where)

      assert declared.specs == [city: {:prim, Name}]
      assert declared.fields == [city: "Город"]
    end

    test "спека и у нагрузки, и в fields: — CompileError" do
      payload = Field.normalize!([name: [prim: Name]], :payload, "нагрузка")

      assert_raise CompileError, ~r/^Labels.Fields X: спека поля и у нагрузки события, и в `fields:`/, fn ->
        Fields.declare!({:payload, payload}, [fields: [name: [prim: Name]], labels: [name: "Название"]], @where)
      end
    end

    test "labels: без нагрузки и без fields: — CompileError" do
      assert_raise CompileError, ~r/^Labels.Fields X: не нагрузка/, fn ->
        Fields.declare!(:struct, [labels: [city: "Город"]], @where)
      end
    end

    test "change: у Core.Es.ValueChanged — вид значения из его type:" do
      assert Fields.declare!({:change, [type: Name, nilable: false]}, [change: "Название"], @where) ==
               %{specs: [], fields: [], change: {"Название", {:prim, Name}}}
    end

    test "change: у ручного struct'а с value: — вид значения из value:" do
      text = &Atom.to_string/1

      assert Fields.declare!(:struct, [change: "Метки", value: [list: [text: text]]], @where).change ==
               {"Метки", {:list, {:text, text}}}
    end

    test "change: у ручного struct'а без value: — CompileError" do
      assert_raise CompileError, ~r/^Labels.Fields X: ручной struct изменения без `value:`/, fn ->
        Fields.declare!(:struct, [change: "Метки"], @where)
      end
    end

    test "change: до defstruct — CompileError" do
      assert_raise CompileError, ~r/^Labels.Fields X: `use Core.Labels.Fields, change:` подключается после/, fn ->
        Fields.declare!(:none, [change: "Метки"], @where)
      end
    end

    test "value: без change: — CompileError" do
      assert_raise CompileError, ~r/^Labels.Fields X: `value:` без `change:`/, fn ->
        Fields.declare!(:struct, [labels: [city: "Город"], value: [prim: Name]], @where)
      end
    end

    test "labels: и change: вместе — CompileError" do
      assert_raise CompileError, "Labels.Fields X: одна из опций `labels:` / `change:`, задано обе", fn ->
        Fields.declare!(:struct, [labels: [city: "Город"], change: "Город"], @where)
      end
    end

    test "ни labels:, ни change: — CompileError" do
      assert_raise CompileError, "Labels.Fields X: одна из опций `labels:` / `change:`, задано ни одной", fn ->
        Fields.declare!(:struct, [], @where)
      end
    end
  end

  describe "спека fields:" do
    test "у нагрузки события — CompileError" do
      assert_raise CompileError, ~r/Both: спека поля и у нагрузки события, и в `fields:`.*\[:name\]/, fn ->
        compile_payload(:Both,
          labels: [name: "Название", note: :hidden],
          fields: [name: [prim: Core.LabelsFixture.Name]]
        )
      end
    end

    test "видимое поле без спеки — CompileError" do
      assert_raise CompileError, ~r/NoSpec: видимые поля без спеки `fields:`: \[:zip\]/, fn ->
        compile_struct(:NoSpec, fields: [city: [prim: Core.LabelsFixture.Name]], labels: [city: "Город", zip: "Индекс"])
      end
    end

    test "спека скрытого поля — CompileError" do
      assert_raise CompileError, ~r/HiddenSpec: спека скрытых полей: \[:zip\]/, fn ->
        compile_struct(:HiddenSpec,
          fields: [city: [prim: Core.LabelsFixture.Name], zip: [type: :string]],
          labels: [city: "Город", zip: :hidden]
        )
      end
    end

    test "спека поля вне struct'а — CompileError" do
      assert_raise CompileError, ~r/ExtraSpec: спека полей вне struct'а: \[:extra\]/, fn ->
        compile_struct(:ExtraSpec,
          fields: [city: [prim: Core.LabelsFixture.Name], zip: [type: :string], extra: [type: :string]],
          labels: [city: "Город", zip: "Индекс"]
        )
      end
    end

    test "спека разбирается нормализатором плагина по полям — его отказ" do
      assert_raise CompileError, ~r/NotPrim: fields, поле city: Core.LabelsFixture.Count.*не Core.Enum/, fn ->
        compile_struct(:NotPrim,
          fields: [city: [enum: Core.LabelsFixture.Count], zip: [type: :string]],
          labels: [city: "Город", zip: "Индекс"]
        )
      end
    end

    test "fields: без labels: — CompileError" do
      assert_raise CompileError, ~r/FieldsOnly: одна из опций `labels:` \/ `change:`/, fn ->
        compile_struct(:FieldsOnly, fields: [city: [prim: Core.LabelsFixture.Name], zip: [type: :string]])
      end
    end

    test "модуль без struct'а — CompileError" do
      assert_raise CompileError, ~r/NoStruct: не struct/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.FieldsTest.NoStruct do
              use Core.Labels.Fields,
                fields: [city: [prim: Core.LabelsFixture.Name]],
                labels: [city: "Город"]
            end
          end
        )
      end
    end

    test "вложенный struct без Core.Labels.Fields — CompileError" do
      assert_raise CompileError, ~r/Bare: вложенный struct без `use Core.Labels.Fields`: \[:zip\]/, fn ->
        compile_struct(:Bare,
          fields: [city: [prim: Core.LabelsFixture.Name], zip: [list: [entity: URI]]],
          labels: [city: "Город", zip: "Индекс"]
        )
      end
    end
  end

  describe "text:" do
    test "не захват — CompileError" do
      assert_raise CompileError, ~r/NotCapture: fields, поле zip: text: захват функции арности 1/, fn ->
        compile_struct(:NotCapture,
          fields: [city: [prim: Core.LabelsFixture.Name], zip: [text: "почтовый"]],
          labels: [city: "Город", zip: "Индекс"]
        )
      end
    end

    test "захват другой арности — CompileError" do
      assert_raise CompileError, ~r/Arity2: fields, поле zip: list: text: захват функции арности 1/, fn ->
        compile_struct(:Arity2,
          fields: [city: [prim: Core.LabelsFixture.Name], zip: [list: [text: &Map.get/2]]],
          labels: [city: "Город", zip: "Индекс"]
        )
      end
    end

    test "анонимная функция — CompileError" do
      assert_raise CompileError, ~r/Anon: fields, поле zip: text: захват функции арности 1/, fn ->
        compile_struct(
          :Anon,
          quote(
            do: [
              fields: [city: [prim: Core.LabelsFixture.Name], zip: [text: fn zip -> zip end]],
              labels: [city: "Город", zip: "Индекс"]
            ]
          )
        )
      end
    end

    test "с другими ключами — CompileError" do
      assert_raise CompileError, ~r/Mixed: fields, поле zip: `text:` без других ключей/, fn ->
        compile_struct(
          :Mixed,
          quote(
            do: [
              fields: [city: [prim: Core.LabelsFixture.Name], zip: [text: &Kernel.to_string/1, optional: true]],
              labels: [city: "Город", zip: "Индекс"]
            ]
          )
        )
      end
    end
  end

  describe "отказ сборки" do
    test "поле без решения — CompileError" do
      assert_raise CompileError, ~r/Missing: поля без подписи или `:hidden`: \[:note\]/, fn ->
        compile_payload(:Missing, labels: [name: "Название"])
      end
    end

    test "подпись поля вне struct'а — CompileError" do
      assert_raise CompileError, ~r/Extra: подписи полей вне struct'а: \[:extra\]/, fn ->
        compile_payload(:Extra, labels: [name: "Название", note: :hidden, extra: "Лишнее"])
      end
    end

    test "повтор поля — CompileError" do
      assert_raise CompileError, ~r/Twice: labels: ключи повторяются \[:name\]/, fn ->
        compile_payload(:Twice, labels: [name: "Название", name: "Имя", note: :hidden])
      end
    end

    test "пустая подпись — CompileError" do
      assert_raise CompileError, ~r/Blank: labels, поле name: непустая строка, задано " "/, fn ->
        compile_payload(:Blank, labels: [name: " ", note: :hidden])
      end
    end

    test "не строковая подпись — CompileError" do
      assert_raise CompileError, ~r/NotText: labels, поле note: непустая строка, задано :shown/, fn ->
        compile_payload(:NotText, labels: [name: "Название", note: :shown])
      end
    end

    test "labels: не keyword-список — CompileError" do
      assert_raise CompileError, ~r/Empty: labels: непустой keyword-список, задано \[\]/, fn ->
        compile_payload(:Empty, labels: [])
      end
    end

    test "без labels: — CompileError" do
      assert_raise CompileError, ~r/NoLabels: одна из опций `labels:` \/ `change:`/, fn ->
        compile_payload(:NoLabels, [])
      end
    end

    test "подпись строкой у свободной map'ы — CompileError" do
      assert_raise CompileError, ~r/Meta: свободная map'а выходит подписями ключа и значения.*: \[:note\]/, fn ->
        compile_payload(:Meta, [labels: [name: "Название", note: "Данные"]], :map)
      end
    end

    test "видимый список map'ов — CompileError: только `:hidden`" do
      assert_raise CompileError, ~r/MapList: список map'ов в сведения не выходит — только `:hidden`: \[:zip\]/, fn ->
        compile_struct(:MapList,
          fields: [city: [prim: Core.LabelsFixture.Name], zip: [list: [type: :map]]],
          labels: [city: "Город", zip: "Индекс"]
        )
      end
    end

    test "подписи map'ы у списка map'ов — CompileError: только `:hidden`" do
      assert_raise CompileError, ~r/MapListLabels: список map'ов в сведения не выходит — только `:hidden`/, fn ->
        compile_struct(:MapListLabels,
          fields: [city: [prim: Core.LabelsFixture.Name], zip: [list: [type: :map]]],
          labels: [city: "Город", zip: [label: "Лимиты", key: "Счёт", value: "Лимит"]]
        )
      end
    end

    test "подписи map'ы у поля, которое не map'а — CompileError" do
      assert_raise CompileError,
                   ~r/NotMap: подписи map'ы `\[label:, key:, value:\]` у поля, которое не map'а: \[:note\]/,
                   fn ->
                     compile_payload(:NotMap,
                       labels: [name: "Название", note: [label: "Данные", key: "Ключ", value: "Значение"]]
                     )
                   end
    end

    test "неизвестный ключ подписей map'ы — CompileError" do
      assert_raise CompileError, ~r/UnknownKey: labels, поле note: неизвестные опции: \[:hint\]/, fn ->
        compile_payload(
          :UnknownKey,
          [labels: [name: "Название", note: [label: "Данные", key: "Ключ", value: "Значение", hint: "?"]]],
          :map
        )
      end
    end

    test "подписи map'ы без ключа — CompileError" do
      assert_raise CompileError, ~r/NoKey: labels, поле note: нет обязательных опций: \[:key\]/, fn ->
        compile_payload(:NoKey, [labels: [name: "Название", note: [label: "Данные", value: "Значение"]]], :map)
      end
    end

    test "пустая подпись ключа map'ы — CompileError" do
      assert_raise CompileError, ~r/BlankKey: labels, поле note: key: непустая строка, задано ""/, fn ->
        compile_payload(
          :BlankKey,
          [labels: [name: "Название", note: [label: "Данные", key: "", value: "Значение"]]],
          :map
        )
      end
    end

    test "use до Core.Es.Event.Payload — CompileError" do
      assert_raise CompileError, ~r/Early: не нагрузка: `use Core.Labels.Fields` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.FieldsTest.Early do
              use Core.Labels.Fields, labels: [name: "Название"]

              use Core.Es.Event.Payload, fields: [name: [prim: Core.LabelsFixture.Name]]
            end
          end
        )
      end
    end

    test "struct без Core.Es.Event.Payload — CompileError" do
      assert_raise CompileError, ~r/Plain: не нагрузка: `use Core.Labels.Fields` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.FieldsTest.Plain do
              defstruct [:name]

              use Core.Labels.Fields, labels: [name: "Название"]
            end
          end
        )
      end
    end
  end

  describe "change:" do
    test "Core.Es.ValueChanged — вида значения в объявлении нет, видимых полей нет" do
      {{:module, module, _bytecode, _result}, _binding} = compile_value_changed(:Changed, change: "Название")

      assert Fields.specs(module) == []
      assert Fields.paths(module) == []
    end

    test "labels: вместе с change: — CompileError" do
      assert_raise CompileError, ~r/Both: одна из опций `labels:` \/ `change:`, задано обе/, fn ->
        compile_value_changed(:Both, change: "Название", labels: [old_value: "Было", new_value: "Стало"])
      end
    end

    test "value: у Core.Es.ValueChanged — CompileError" do
      assert_raise CompileError, ~r/Typed: `value:` у `Core.Es.ValueChanged` — вид значения задаёт его `type:`/, fn ->
        compile_value_changed(:Typed, change: "Название", value: [prim: Core.LabelsFixture.Name])
      end
    end

    test "fields: вместе с change: — CompileError" do
      assert_raise CompileError, ~r/WithFields: `fields:` вместе с `change:`/, fn ->
        compile_value_changed(:WithFields, change: "Название", fields: [old_value: [prim: Core.LabelsFixture.Name]])
      end
    end

    test "пустая подпись изменения — CompileError" do
      assert_raise CompileError, ~r/BlankChange: change: непустая строка, задано ""/, fn ->
        compile_value_changed(:BlankChange, change: "")
      end
    end

    test "use выше Core.Es.ValueChanged — CompileError" do
      assert_raise CompileError, ~r/Late: `use Core.Labels.Fields, change:` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.FieldsTest.Late do
              use Core.Labels.Fields,
                change: "Название",
                value: [prim: Core.LabelsFixture.Name]

              use Core.Es.ValueChanged, type: Core.LabelsFixture.Name
            end
          end
        )
      end
    end

    test "ручной struct изменения без value: — CompileError" do
      assert_raise CompileError, ~r/NoValue: ручной struct изменения без `value:`/, fn ->
        compile_change(:NoValue, [:old_value, :new_value], change: "Значение")
      end
    end

    test "value: без change: — CompileError" do
      assert_raise CompileError, ~r/Orphan: `value:` без `change:`/, fn ->
        compile_change(:Orphan, [:old_value, :new_value],
          labels: [old_value: "Было", new_value: "Стало"],
          value: [type: :string]
        )
      end
    end

    test "struct без old_value / new_value — CompileError" do
      assert_raise CompileError, ~r/Current: struct изменения без полей: \[:new_value\]/, fn ->
        compile_change(:Current, [:old_value, :current], change: "Значение", value: [type: :string])
      end
    end

    test "лишнее поле struct'а изменения — CompileError" do
      assert_raise CompileError,
                   ~r/Reason: поля struct'а изменения вне `old_value` \/ `new_value`: \[:reason\]/,
                   fn ->
                     compile_change(:Reason, [:old_value, :new_value, :reason],
                       change: "Значение",
                       value: [type: :string]
                     )
                   end
    end

    test "value: разбирается нормализатором плагина по полям — его отказ" do
      assert_raise CompileError, ~r/NotEnum: value, .*Core.LabelsFixture.Count.*не Core.Enum/, fn ->
        compile_change(:NotEnum, [:old_value, :new_value], change: "Значение", value: [enum: Core.LabelsFixture.Count])
      end
    end

    test "value: text: не захватом — CompileError" do
      assert_raise CompileError, ~r/NotCaptureValue: value, .*text: захват функции арности 1/, fn ->
        compile_change(:NotCaptureValue, [:old_value, :new_value], change: "Значение", value: [text: "текст"])
      end
    end

    test "вложенный struct без Core.Labels.Fields — CompileError" do
      assert_raise CompileError,
                   ~r/BareValue: вложенный struct без `use Core.Labels.Fields`: \[:old_value, :new_value\]/,
                   fn ->
                     compile_change(:BareValue, [:old_value, :new_value], change: "Значение", value: [entity: URI])
                   end
    end

    test "значение-map'а и список map'ов на любой глубине — CompileError без советов" do
      values = [MapValue: [type: :map], MapListValue: [list: [type: :map]], MapListsValue: [list: [list: [type: :map]]]]

      for {name, value} <- values do
        error =
          assert_raise CompileError, fn ->
            compile_change(name, [:old_value, :new_value], change: "Значение", value: value)
          end

        assert error.description =~
                 "#{name}: значение изменения — map'а или список map'ов: в сведения не выходит, подписать его нельзя"

        refute error.description =~ ":hidden"
        refute error.description =~ "[label:, key:, value:]"
      end
    end
  end

  test "map'а с подписями ключа и значения собирается; спека — map" do
    {{:module, module, _bytecode, _result}, _binding} =
      compile_payload(
        :LabelledMap,
        [labels: [name: "Название", note: [value: "Лимит", key: "Счёт", label: "Лимиты"]]],
        :map
      )

    assert Fields.specs(module) == [name: {:prim, Name}, note: {:type, :map}]
    assert Fields.paths(module) == [{[:name], "Название"}, {[:note], "Лимиты"}]
  end

  test "свободная map под :hidden собирается" do
    {{:module, module, _bytecode, _result}, _binding} =
      compile_payload(:HiddenMap, [labels: [name: "Название", note: :hidden]], :map)

    assert Fields.specs(module) == [name: {:prim, Name}]
  end

  # ---

  defp compile_struct(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          defstruct [:city, :zip]

          use Core.Labels.Fields, unquote(opts)
        end
      end
    )
  end

  defp compile_value_changed(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.ValueChanged, type: Core.LabelsFixture.Name

          use Core.Labels.Fields, unquote(opts)
        end
      end
    )
  end

  defp compile_change(name, fields, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          defstruct unquote(fields)

          use Core.Labels.Fields, unquote(opts)
        end
      end
    )
  end

  defp compile_payload(name, opts, note_type \\ :string) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Event.Payload,
            fields: [
              name: [prim: Core.LabelsFixture.Name],
              note: [type: unquote(note_type), optional: true]
            ]

          use Core.Labels.Fields, unquote(opts)
        end
      end
    )
  end
end
