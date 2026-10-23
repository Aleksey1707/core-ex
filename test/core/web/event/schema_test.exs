defmodule Core.Web.Event.SchemaTest do
  use ExUnit.Case, async: true

  alias Core.Web.Event
  alias Core.WebEventFixture.UserRef
  alias OpenApiSpex.Reference
  alias OpenApiSpex.Schema

  @fields ~w(id aggregateId aggregateVersion type payload at by)a

  describe "event/3" do
    test "без user_ref: — by строкой, все поля конверта обязательны" do
      assert %Schema{title: "Plain", type: :object, required: required, properties: properties} =
               Event.Schema.event("Plain", nil, nil)

      assert Enum.sort(required) == Enum.sort(@fields)
      assert Enum.sort(Map.keys(properties)) == Enum.sort(@fields)

      assert %{
               type: %Schema{type: :string, enum: nil},
               aggregateVersion: %Schema{type: :integer, minimum: 1},
               payload: %Schema{type: nil, nullable: true},
               at: %Schema{type: :string, format: :"date-time"},
               by: %Schema{type: :string}
             } = properties
    end

    test "с user_ref: — by схемой учётной записи" do
      assert %Schema{properties: %{by: UserRef}} = Event.Schema.event("WithUser", UserRef, nil)
    end

    test "labels: true — title и details со схемой сведения, обязательны" do
      assert %Schema{required: required, properties: properties} =
               Event.Schema.event("WebEvent", UserRef, __MODULE__.Detail)

      assert Enum.sort(required) == Enum.sort(@fields ++ ~w(title details)a)
      assert %{title: %Schema{type: :string}, details: %Schema{type: :array, items: __MODULE__.Detail}} = properties
    end
  end

  describe "detail/2" do
    test "oneOf по модулям видов, дискриминатор kind — на названия схем видов" do
      variants = [text: __MODULE__.Text, change: __MODULE__.Change]

      assert %Schema{
               title: "WebEventDetail",
               oneOf: [__MODULE__.Text, __MODULE__.Change],
               discriminator: %OpenApiSpex.Discriminator{propertyName: "kind", mapping: mapping}
             } = Event.Schema.detail("WebEvent", variants)

      assert mapping == %{
               "text" => "#/components/schemas/WebEventDetailText",
               "change" => "#/components/schemas/WebEventDetailChange"
             }
    end
  end

  describe "variant/3" do
    test "change — old и new ссылкой на схему сведения, подпись обязательна" do
      detail = %Reference{"$ref": "#/components/schemas/WebEventDetail"}

      assert %Schema{
               title: "WebEventDetailChange",
               properties: %{kind: %Schema{enum: ["change"]}, old: ^detail, new: ^detail},
               required: ~w(label kind old new)a
             } = Event.Schema.variant("WebEvent", :change, UserRef)
    end

    test "destroyed — без значения, обязателен только kind" do
      assert %Schema{title: "WebEventDetailDestroyed", properties: properties, required: [:kind]} =
               Event.Schema.variant("WebEvent", :destroyed, UserRef)

      assert Enum.sort(Map.keys(properties)) == ~w(kind label)a
    end

    test "user — значение схемой учётной записи, nullable" do
      assert %Schema{properties: %{value: %Schema{allOf: [UserRef], nullable: true}}, required: ~w(kind value)a} =
               Event.Schema.variant("WebEvent", :user, UserRef)
    end
  end
end
