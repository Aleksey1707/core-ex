defmodule Core.Helper.MapTest do
  use ExUnit.Case, async: true

  alias Core.Helper

  test "fetch/2 находит значение по atom-ключу" do
    assert {:ok, 1} = Helper.Map.fetch(%{attempt: 1}, :attempt)
  end

  test "fetch/2 находит значение по одноимённому string-ключу" do
    assert {:ok, 1} = Helper.Map.fetch(%{"attempt" => 1}, :attempt)
  end

  test "fetch/2 отличает явный nil от отсутствия ключа" do
    assert {:ok, nil} = Helper.Map.fetch(%{attempt: nil}, :attempt)
    assert {:ok, nil} = Helper.Map.fetch(%{"attempt" => nil}, :attempt)
    assert :error = Helper.Map.fetch(%{}, :attempt)
  end

  test "fetch/2 отдаёт приоритет atom-ключу" do
    assert {:ok, :atom} = Helper.Map.fetch(%{:attempt => :atom, "attempt" => :string}, :attempt)
    assert {:ok, nil} = Helper.Map.fetch(%{:attempt => nil, "attempt" => :string}, :attempt)
  end

  test "field/2 возвращает значение или nil" do
    assert Helper.Map.field(%{attempt: 1}, :attempt) == 1
    assert Helper.Map.field(%{"attempt" => 1}, :attempt) == 1
    assert Helper.Map.field(%{"attempt" => 1}, :message) == nil
    assert Helper.Map.field(%{}, :attempt) == nil
  end

  test "field/2 отдаёт приоритет atom-ключу" do
    assert Helper.Map.field(%{:attempt => :atom, "attempt" => :string}, :attempt) == :atom
  end
end
