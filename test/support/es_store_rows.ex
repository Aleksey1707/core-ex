defmodule Core.Es.Store.Rows do
  @moduledoc """
  Строки `es_events` из литературы и тестовый источник строк `Core.Es.Aggregate.Load`.

  `rows/1` строит строки в форме хранилища, `fetch/3` реализует
  `Core.Es.Aggregate.Load.Source`: выбирает строки и снапшот каждого потока по готовым границам
  плана. Опции: `rows:` — строки, `snapshots:` — `{id, version, state}`, `order: :reverse` —
  обратный порядок потоков.
  """

  @behaviour Core.Es.Aggregate.Load.Source

  alias Core.Es.Aggregate.Load.Plan
  alias Core.Es.Store.Schema

  @doc "Строки `es_events` из `{type, aggregate_id, version, tag, payload}`."
  @spec rows([{String.t(), binary(), pos_integer(), String.t(), term()}]) :: [Schema.t()]

  def rows(entries) do
    for {type, aggregate_id, version, tag, payload} <- entries do
      %Schema{
        aggregate_type: type,
        aggregate_id: aggregate_id,
        aggregate_version: version,
        event_id: Core.Prim.UUID.generate(7),
        tag: tag,
        payload: payload,
        by_id: by_id(),
        at: DateTime.utc_now(:second)
      }
    end
  end

  @impl true
  @spec fetch(map(), Plan.t(), keyword()) :: [Core.Es.Aggregate.Load.Source.entry()]

  def fetch(cfg, %Plan{streams: streams}, opts) do
    rows = Keyword.fetch!(opts, :rows)
    snapshots = Keyword.get(opts, :snapshots, [])
    streams = if Keyword.get(opts, :order) == :reverse, do: Enum.reverse(streams), else: streams

    Enum.map(streams, &triple(cfg, &1, rows, snapshots))
  end

  # ---

  defp by_id, do: Core.Config.codec().dump(Core.EsFixture.UserID.new())

  defp triple(cfg, stream, rows, snapshots) do
    candidates =
      for {id, version, state} <- snapshots,
          cfg.codec.dump(id) == stream.aggregate_id,
          do: {version, :erlang.term_to_binary(state)}

    snapshot = Plan.snapshot(stream, candidates)
    from_version = from_version(stream, snapshot)

    events =
      for row <- rows,
          row.aggregate_id == stream.aggregate_id,
          row.aggregate_version > from_version,
          is_nil(stream.to_version) or row.aggregate_version <= stream.to_version,
          do: row

    {stream, snapshot, events}
  end

  defp from_version(stream, nil), do: stream.after_version
  defp from_version(stream, {version, _binary}), do: max(stream.after_version, version)
end
