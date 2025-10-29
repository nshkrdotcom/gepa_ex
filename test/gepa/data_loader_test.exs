defmodule GEPA.DataLoaderTest do
  use ExUnit.Case, async: true

  alias GEPA.DataLoader

  describe "DataLoader.List" do
    test "new/1 creates loader with items" do
      items = [%{a: 1}, %{a: 2}, %{a: 3}]
      loader = DataLoader.List.new(items)

      assert %DataLoader.List{items: ^items} = loader
    end

    test "all_ids/1 returns integer indices" do
      items = [:a, :b, :c, :d]
      loader = DataLoader.List.new(items)

      assert DataLoader.all_ids(loader) == [0, 1, 2, 3]
    end

    test "fetch/2 returns items in order of IDs" do
      items = [:a, :b, :c, :d]
      loader = DataLoader.List.new(items)

      assert DataLoader.fetch(loader, [2, 0, 3]) == [:c, :a, :d]
    end

    test "fetch/2 preserves duplicates" do
      items = [:a, :b, :c]
      loader = DataLoader.List.new(items)

      assert DataLoader.fetch(loader, [0, 0, 1]) == [:a, :a, :b]
    end

    test "size/1 returns count of items" do
      items = [1, 2, 3, 4, 5]
      loader = DataLoader.List.new(items)

      assert DataLoader.size(loader) == 5
    end

    test "size/1 returns 0 for empty list" do
      loader = DataLoader.List.new([])

      assert DataLoader.size(loader) == 0
    end
  end
end
