defmodule Core.Labels.CompletenessCaseFamilyTest do
  use ExUnit.Case, async: true

  alias Core.Labels.CompletenessCase
  alias Core.LabelsFamilyFixture.Event
  alias Core.LabelsFamilyFixture.Foreign
  alias Core.LabelsFamilyFixture.Legacy
  alias Core.LabelsFamilyFixture.Loose
  alias Core.LabelsFamilyFixture.Mark

  describe "check_variants/1: реестр семейства" do
    test "семейство с реестром без локального плагина — unknown_family нет, варианты проверены" do
      assert :ok = CompletenessCase.check_variants([Event.Mixed.Codec])
    end

    test "семейство без реестра с плагином — варианты из плагина, unknown_family нет" do
      assert :ok = CompletenessCase.check_variants([Event.Legacy.Codec, Legacy.Codec])
    end

    test "семейство без реестра и без плагина — владелец, поле и семейство" do
      assert {:error, %{unknown_family: [{Event.Loose.Payload, :loose, Loose}]}} =
               CompletenessCase.check_variants([Event.Loose.Codec])
    end
  end

  describe "check_fields/1: варианты смешанного плагина" do
    test "чужой декларативный тип не вариант: пробела у поля семейства нет" do
      assert :ok = CompletenessCase.check_fields([Event.Mixed.Codec, Mark.Codec])
    end

    test "тот же тип — вариант другого семейства: пробел у поля этого семейства, а не у чужого" do
      assert {:error, %{undecided: [{Event.Foreign.Payload, :other, Foreign}]}} =
               CompletenessCase.check_fields([Event.Mixed.Codec, Event.Foreign.Codec, Mark.Codec])
    end
  end

  describe "check_fields/1: семейство без реестра" do
    test "варианты находятся через типы плагина: необъявленный вариант — пробел" do
      assert {:error, %{undecided: [{Event.Legacy.Payload, :legacy, Legacy.Bare}]}} =
               CompletenessCase.check_fields([Event.Legacy.Codec, Legacy.Codec])
    end
  end

  describe "check_ids/1: варианты из реестра" do
    test "вариант-Prim семейства с реестром проверяется как id и без локального плагина" do
      assert :ok = CompletenessCase.check_ids([Event.Mixed.Codec])
    end
  end
end
