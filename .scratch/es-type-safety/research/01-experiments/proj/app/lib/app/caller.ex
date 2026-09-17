defmodule App.Caller do
  def local_direct, do: App.Local.to_int("x")
  def local_via_facade, do: App.Facade.to_int("x")
  def local_via_guarded_facade, do: App.Facade.to_int_guarded("x")
  def local_via_defdelegate, do: App.Facade.delegated_to_int("x")
  def dep_direct, do: DepLib.to_int("x")
  def dep_via_app_facade, do: App.Facade.dep_to_int("x")
  def dep_via_dep_facade, do: DepLib.Facade.to_int("x")

  def local_status do
    case App.Local.status() do
      :ok -> :ok
      :error -> :never
    end
  end

  def local_status_via_facade do
    case App.Facade.status() do
      :ok -> :ok
      :error -> :never
    end
  end

  def dep_status_via_app_facade do
    case App.Facade.dep_status() do
      :ok -> :ok
      :error -> :never
    end
  end

  def dep_status_via_dep_facade do
    case DepLib.Facade.status() do
      :ok -> :ok
      :error -> :never
    end
  end

  def app_protocol, do: App.Proto.dump("x")
  def dep_protocol, do: DepLib.Dump.dump("x")
  def string_chars, do: "#{%App.Local{}}"
  def enumerable, do: for(x <- %App.Local{}, do: x)
end
