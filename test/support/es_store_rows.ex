defmodule Core.Es.Store.Rows do
  @moduledoc """
  Строки `es_events` из литературы и заглушка порта `Core.Es.Aggregate.Load`.

  `rows/1` строит строки в форме хранилища, `source/2` — функцию-источник, которая отдаёт пары
  «мета потока + снапшот + строки» без базы.
  """

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

  @doc """
  Источник строк для `Core.Es.Aggregate.Load`: фильтрует `rows` по мете потока и отдаёт снапшот
  `{id, version, state}` не выше `snapshot_to`.
  """
  @spec source([Schema.t()], [{struct(), pos_integer(), struct()}]) :: Core.Es.Aggregate.Load.source()

  def source(rows, snapshots \\ []) do
    fn cfg, metas, _opts -> Enum.map(metas, &triple(cfg, &1, rows, snapshots)) end
  end

  # ---

  defp by_id, do: Core.Config.codec().dump(Core.EsFixture.UserID.new())

  defp triple(cfg, meta, rows, snapshots) do
    snapshot = snapshot(cfg, meta, snapshots)
    after_version = after_snapshot(meta.after_version, snapshot)

    events =
      Enum.filter(rows, fn row ->
        row.aggregate_id == meta.aggregate_id and
          row.aggregate_version > after_version and
          (is_nil(meta.to_version) or row.aggregate_version <= meta.to_version)
      end)

    {meta, snapshot, events}
  end

  # Хвост начинается после снапшота: порт читает его join'ом от версии снапшота.
  defp after_snapshot(after_version, nil), do: after_version
  defp after_snapshot(after_version, {version, _binary}), do: max(after_version, version)

  defp snapshot(_cfg, %{snapshot?: false}, _snapshots), do: nil

  defp snapshot(cfg, meta, snapshots) do
    matches =
      for {id, version, state} <- snapshots,
          cfg.codec.dump(id) == meta.aggregate_id,
          version > meta.after_version,
          is_nil(meta.snapshot_to) or version <= meta.snapshot_to,
          do: {version, state}

    case matches do
      [] ->
        nil

      _ ->
        {version, state} = Enum.max_by(matches, &elem(&1, 0))
        {version, :erlang.term_to_binary(state)}
    end
  end
end
