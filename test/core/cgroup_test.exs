defmodule Core.CgroupTest do
  use ExUnit.Case, async: true

  alias Core.Cgroup

  setup do
    dir = System.tmp_dir!()
    path = Path.join(dir, "cgroup-memory-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "читает байты из файла", %{path: path} do
    File.write!(path, "12345\n")
    assert {:ok, 12_345} = Cgroup.memory_current(current_path: path)
  end

  test "отсутствующий путь → :unavailable" do
    assert :unavailable =
             Cgroup.memory_current(
               current_path: "/tmp/definitely-missing-cgroup-#{:erlang.unique_integer()}"
             )
  end

  test "мусор в файле → :unavailable", %{path: path} do
    File.write!(path, "not-a-number\n")
    assert :unavailable = Cgroup.memory_current(current_path: path)
  end

  describe "memory_max/1" do
    test "читает лимит", %{path: path} do
      File.write!(path, "2097152\n")
      assert {:ok, 2_097_152} = Cgroup.memory_max(max_path: path)
    end

    test "v2 `max` → :unlimited", %{path: path} do
      File.write!(path, "max\n")
      assert :unlimited = Cgroup.memory_max(max_path: path)
    end

    test "отсутствующий путь → :unavailable" do
      assert :unavailable =
               Cgroup.memory_max(max_path: "/tmp/missing-cgroup-#{:erlang.unique_integer()}")
    end
  end

  describe "memory_anon/1" do
    test "v2: ключ anon", %{path: path} do
      File.write!(path, "anon 100\nfile 900\ninactive_file 800\n")
      assert {:ok, 100} = Cgroup.memory_anon(stat_path: path)
    end

    test "v1: ключ total_rss", %{path: path} do
      File.write!(path, "cache 900\nrss 90\ntotal_rss 100\n")
      assert {:ok, 100} = Cgroup.memory_anon(stat_path: path)
    end

    test "нет ключа → :unavailable", %{path: path} do
      File.write!(path, "file 900\ninactive_file 800\n")
      assert :unavailable = Cgroup.memory_anon(stat_path: path)
    end

    test "отсутствующий путь → :unavailable" do
      assert :unavailable =
               Cgroup.memory_anon(stat_path: "/tmp/missing-cgroup-#{:erlang.unique_integer()}")
    end
  end

  describe "путь cgroup процесса" do
    test "берётся из /proc/self/cgroup", %{path: path} do
      root = Path.join(System.tmp_dir!(), "cg-#{System.unique_integer([:positive])}")
      scoped = Path.join([root, "system.slice/app.scope"])
      File.mkdir_p!(scoped)
      File.write!(Path.join(scoped, "memory.current"), "777\n")
      File.write!(Path.join(root, "memory.current"), "111\n")
      File.write!(path, "0::/system.slice/app.scope\n")
      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, 777} = Cgroup.memory_current(mount_point: root, self_cgroup_path: path)
    end

    test "без /proc/self/cgroup читается корневой путь", %{path: path} do
      root = Path.join(System.tmp_dir!(), "cg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "memory.current"), "111\n")
      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, 111} =
               Cgroup.memory_current(mount_point: root, self_cgroup_path: path <> "-missing")
    end
  end
end
