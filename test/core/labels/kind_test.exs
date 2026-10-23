defmodule Core.Labels.KindTest.Author do
  @moduledoc "Композит над композитом с объявлением базы."

  use Core.Prim.Compose,
    name: "Автор записи",
    of: Core.LabelsFixture.AuthorID
end

defmodule Core.Labels.KindTest.Owner do
  @moduledoc "Композит со своим объявлением над id с другим видом."

  use Core.Prim.Compose,
    name: "Владелец",
    of: Core.LabelsFixture.ItemID

  use Core.Labels.ID,
    kind: :user,
    resolver: Core.LabelsFixture.UserQuery
end

defmodule Core.Labels.KindTest.Email do
  @moduledoc "Prim со своим kind."

  use Core.Prim.String,
    name: "Почта",
    kind: :email,
    max_len: 50
end

defmodule Core.Labels.KindTest.Contact do
  @moduledoc "Композит над Prim со своим kind."

  use Core.Prim.Compose,
    name: "Контакт",
    of: Core.Labels.KindTest.Email
end

defmodule Core.Labels.KindTest.BareRef do
  @moduledoc "Композит над id без вида."

  use Core.Prim.Compose,
    name: "Ссылка без вида",
    of: Core.LabelsFixture.BareID
end

defmodule Core.Labels.KindTest do
  use ExUnit.Case, async: true

  alias Core.Labels.Kind
  alias Core.Labels.KindTest.Author
  alias Core.Labels.KindTest.BareRef
  alias Core.Labels.KindTest.Contact
  alias Core.Labels.KindTest.Email
  alias Core.Labels.KindTest.Owner
  alias Core.LabelsFixture.Amount
  alias Core.LabelsFixture.AuthorID
  alias Core.LabelsFixture.BareID
  alias Core.LabelsFixture.BaseUnit
  alias Core.LabelsFixture.Count
  alias Core.LabelsFixture.Day
  alias Core.LabelsFixture.ItemID
  alias Core.LabelsFixture.Moment
  alias Core.LabelsFixture.Name
  alias Core.LabelsFixture.SnapshotID
  alias Core.LabelsFixture.Title
  alias Core.LabelsFixture.Unit
  alias Core.LabelsFixture.UserID

  describe "of/1" do
    test "leaf без объявления — вид leaf-Prim" do
      assert Kind.of(Name) == {:plain, :text}
      assert Kind.of(Count) == {:plain, :number}
      assert Kind.of(Amount) == {:plain, :number}
      assert Kind.of(Day) == {:plain, :date}
      assert Kind.of(Moment) == {:plain, :datetime}
    end

    test "Prim с Labels.Text — объявление текста, владелец — сам Prim" do
      assert {:declared, Unit, {:text, fun}} = Kind.of(Unit)
      assert fun == (&Core.LabelsFixture.Texts.unit/1)
    end

    test "Labels.ID — объявление вида id, владелец — сам Prim" do
      assert {:declared, ItemID, %{kind: :ref, entity: :stock_item, resolver: Core.LabelsFixture.ItemQuery}} =
               Kind.of(ItemID)

      assert {:declared, UserID, %{kind: :user, resolver: Core.LabelsFixture.UserQuery}} = Kind.of(UserID)
      assert {:declared, SnapshotID, %{kind: :id, resolver: nil}} = Kind.of(SnapshotID)
    end

    test "композит без своего объявления — объявление базы, владелец — база" do
      assert {:declared, UserID, %{kind: :user}} = Kind.of(AuthorID)
      assert {:declared, Unit, {:text, _fun}} = Kind.of(BaseUnit)
      assert Kind.of(Title) == {:plain, :text}
    end

    test "вложенный композит — объявление ближайшего звена с ним" do
      assert {:declared, UserID, %{kind: :user}} = Kind.of(Author)
    end

    test "композит со своим объявлением — своё, а не базы" do
      assert {:declared, Owner, %{kind: :user, entity: nil}} = Kind.of(Owner)
    end

    test "kind: :uuid без объявления и композит над ним — id без вида с leaf-Prim" do
      assert Kind.of(BareID) == {:unkinded, BareID}
      assert Kind.of(BareRef) == {:unkinded, BareID}
    end

    test "свой kind leaf без объявления и композит над ним — вида нет, с leaf-Prim" do
      assert Kind.of(Email) == {:custom, Email}
      assert Kind.of(Contact) == {:custom, Email}
    end
  end

  describe "owned/2" do
    test "значение владельца — сам Prim или база композита на любой глубине" do
      user = UserID.new()
      author = Author.new!(AuthorID.new!(user))

      assert Kind.owned(user, UserID) == user
      assert Kind.owned(author, UserID) == user

      owner = Owner.new!(ItemID.new())
      assert Kind.owned(owner, Owner) == owner

      unit = Unit.new!("kg")
      assert Kind.owned(BaseUnit.new!(unit), Unit) == unit
    end
  end
end
