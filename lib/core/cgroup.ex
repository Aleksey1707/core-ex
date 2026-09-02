defmodule Core.Cgroup do
  @moduledoc """
  Чтение cgroup memory (контейнер / Linux cgroup).

  Путь берётся из `/proc/self/cgroup` — это cgroup **процесса**, а не корневой:
  на хосте без cgroup-namespace (systemd-slice, k8s с общим cgroupfs, вложенные
  контейнеры) корневые файлы относятся к чужому scope и метрика врёт. Если файл
  процесса недоступен, читается корневой путь как раньше.

  Сначала cgroup v2 (`memory.current` / `memory.max` / `memory.stat`), затем v1
  (`memory/memory.usage_in_bytes` / `memory/memory.limit_in_bytes` / `memory/memory.stat`).
  Вне контейнера обычно `:unavailable`.
  """

  @mount_point "/sys/fs/cgroup"
  @self_cgroup_path "/proc/self/cgroup"

  @v2_current "memory.current"
  @v2_max "memory.max"
  @v2_stat "memory.stat"
  @v1_current "memory/memory.usage_in_bytes"
  @v1_max "memory/memory.limit_in_bytes"
  @v1_stat "memory/memory.stat"

  # v1 без лимита пишет «очень большое число» вместо признака отсутствия.
  @v1_unlimited 0x7FFFFFFFFFFFF000

  # Анонимная память в memory.stat: имя v2, затем иерархическое и локальное имена v1.
  @anon_keys ~w(anon total_rss rss)

  @doc """
  Текущее потребление ОЗУ cgroup в байтах.

  Считает вместе со страничным кешем; память приложения — `memory_anon/1`.

  Opts: `:current_path` — явный путь к файлу (тесты / DI), `:mount_point`,
  `:self_cgroup_path`.
  """
  @spec memory_current() :: {:ok, non_neg_integer()} | :unavailable
  @spec memory_current(keyword()) :: {:ok, non_neg_integer()} | :unavailable

  def memory_current(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :current_path) do
      path when is_binary(path) -> read_bytes(path)
      nil -> read_first(opts, @v2_current, @v1_current, &read_bytes/1)
    end
  end

  @doc """
  Анонимная память cgroup в байтах (`memory.stat`).

  Это память самого приложения: страничный кеш прочитанных файлов в неё не входит,
  в отличие от `memory.current`. То же значение показывает `podman stats`.

  Имя ключа у v2 (`anon`) и v1 (`total_rss` / `rss`) разное, наружу отдаются байты.

  Opts: `:stat_path` — явный путь к файлу (тесты / DI), `:mount_point`,
  `:self_cgroup_path`.
  """
  @spec memory_anon() :: {:ok, non_neg_integer()} | :unavailable
  @spec memory_anon(keyword()) :: {:ok, non_neg_integer()} | :unavailable

  def memory_anon(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :stat_path) do
      path when is_binary(path) -> read_anon(path)
      nil -> read_first(opts, @v2_stat, @v1_stat, &read_anon/1)
    end
  end

  @doc """
  Лимит памяти cgroup в байтах.

  `:unlimited` — лимит не задан (v2 `max`, v1 «бесконечное» значение); без него
  утилизацию (`current / max`) посчитать не из чего.

  Opts: `:max_path` — явный путь к файлу, `:mount_point`, `:self_cgroup_path`.
  """
  @spec memory_max() :: {:ok, pos_integer()} | :unlimited | :unavailable
  @spec memory_max(keyword()) :: {:ok, pos_integer()} | :unlimited | :unavailable

  def memory_max(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :max_path) do
      path when is_binary(path) -> read_limit(path)
      nil -> with :unavailable <- read_limit(path_for(opts, @v2_max)), do: v1_limit(opts)
    end
  end

  # ---

  defp read_first(opts, v2_file, v1_file, reader) do
    with :unavailable <- reader.(path_for(opts, v2_file)) do
      reader.(path_for(opts, v1_file))
    end
  end

  defp read_anon(path) do
    case read_raw(path) do
      {:ok, contents} -> stat_value(parse_stat(contents), @anon_keys)
      :unavailable -> :unavailable
    end
  end

  defp stat_value(raw, [key | rest]) do
    case Map.fetch(raw, key) do
      {:ok, value} -> parse_bytes(value)
      :error -> stat_value(raw, rest)
    end
  end

  defp stat_value(_raw, []), do: :unavailable

  defp parse_stat(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ", parts: 2) do
        [key, value] -> [{key, value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp v1_limit(opts) do
    case read_limit(path_for(opts, @v1_max)) do
      {:ok, bytes} when bytes >= @v1_unlimited -> :unlimited
      other -> other
    end
  end

  defp read_limit(path) do
    case read_raw(path) do
      {:ok, "max"} -> :unlimited
      {:ok, contents} -> parse_bytes(contents)
      :unavailable -> :unavailable
    end
  end

  defp read_bytes(path) do
    case read_raw(path) do
      {:ok, contents} -> parse_bytes(contents)
      :unavailable -> :unavailable
    end
  end

  # Путь собирается из точки монтирования и относительного пути cgroup процесса —
  # пользовательского ввода в нём нет.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_raw(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim(contents)}
      {:error, _} -> :unavailable
    end
  end

  defp parse_bytes(contents) do
    case Integer.parse(contents) do
      {bytes, ""} when bytes >= 0 -> {:ok, bytes}
      _ -> :unavailable
    end
  end

  defp path_for(opts, file) do
    mount = Keyword.get(opts, :mount_point, @mount_point)

    case self_cgroup(opts) do
      {:ok, relative} -> Path.join([mount, relative, file])
      :unavailable -> Path.join(mount, file)
    end
  end

  # v2-строка `/proc/self/cgroup`: `0::<relative-path>`. Корень (`/`) даёт тот же путь,
  # что и раньше, поэтому отдельной ветки не требует.
  defp self_cgroup(opts) do
    path = Keyword.get(opts, :self_cgroup_path, @self_cgroup_path)

    with {:ok, contents} <- read_raw(path),
         [_ | _] = lines <- String.split(contents, "\n", trim: true),
         relative when is_binary(relative) <- v2_relative_path(lines) do
      {:ok, String.trim_leading(relative, "/")}
    else
      _ -> :unavailable
    end
  end

  defp v2_relative_path(lines) do
    Enum.find_value(lines, fn line ->
      case String.split(line, ":", parts: 3) do
        ["0", "", relative] -> relative
        _ -> nil
      end
    end)
  end
end
