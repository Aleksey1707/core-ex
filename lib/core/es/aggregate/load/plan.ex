defmodule Core.Es.Aggregate.Load.Plan do
  @moduledoc false

  alias Core.Es.Aggregate.Repo.Pg.Config
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Version

  @enforce_keys ~w(marker sealed? every write_snapshots? streams)a

  defstruct marker: nil,
            sealed?: false,
            every: nil,
            write_snapshots?: false,
            streams: []

  @typedoc false
  @type stream :: %{
          aggregate_id: binary(),
          after_version: non_neg_integer(),
          to_version: pos_integer() | nil,
          snapshot_to: pos_integer() | nil
        }

  @typedoc false
  @type t :: %__MODULE__{
          marker: String.t() | nil,
          sealed?: boolean(),
          every: pos_integer() | nil,
          write_snapshots?: boolean(),
          streams: [stream()]
        }

  @typep spec :: %{
           state: struct(),
           version: Version.expected() | nil,
           upper: pos_integer() | nil,
           captures: [pos_integer()]
         }

  @doc false
  @spec new(Config.t(), boolean(), [spec()]) :: t()

  def new(cfg, write_snapshots?, specs) do
    marker = cfg.snapshot && Snapshot.marker(cfg)

    %__MODULE__{
      marker: marker,
      sealed?: marker != nil and cfg.snapshot.sealed,
      every: marker && cfg.snapshot.every,
      write_snapshots?: write_snapshots?,
      streams: Enum.map(specs, &stream(cfg, &1, marker != nil))
    }
  end

  @doc false
  @spec refold(t(), [binary()]) :: t()

  def refold(%__MODULE__{streams: streams} = plan, addresses) do
    wanted = MapSet.new(addresses)

    streams =
      for %{aggregate_id: address, after_version: after_version} = stream <- streams,
          MapSet.member?(wanted, address),
          do: %{stream | snapshot_to: after_version}

    %{plan | streams: streams}
  end

  # ---

  defp stream(cfg, spec, snapshot?) do
    after_version = after_version(spec.state)

    %{
      aggregate_id: cfg.codec.dump(spec.state.id),
      after_version: after_version,
      to_version: to_version(spec),
      snapshot_to: if(snapshot?, do: snapshot_to(spec), else: after_version)
    }
  end

  defp to_version(%{captures: [_ | _] = captures}), do: Enum.max(captures)
  defp to_version(%{upper: upper}), do: upper

  defp snapshot_to(%{captures: [_ | _] = captures}), do: Enum.min(captures)
  defp snapshot_to(%{upper: upper}), do: upper

  defp after_version(%{version: nil}), do: 0
  defp after_version(%{version: %Version{} = version}), do: Version.value(version)
end
