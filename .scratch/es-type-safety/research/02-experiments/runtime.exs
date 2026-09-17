alias Blind.{Account, Order, Parcel, BadDecide, BadEvolve, BadEvolveState, BadProjection, QcStyle}
alias Blind.Codec.Internal, as: InCodec
alias Blind.S
alias Core.Es
alias Core.Version

run = fn label, fun ->
  result =
    try do
      {:returned, fun.()}
    rescue
      e ->
        {mod, f, a} =
          case __STACKTRACE__ do
            [{m, f, a, _} | _] -> {m, f, if(is_list(a), do: length(a), else: a)}
          end

        msg = e |> Exception.message() |> String.split("\n") |> hd() |> String.slice(0, 110)
        {:raised, "#{inspect(e.__struct__)} в #{inspect(mod)}.#{f}/#{a}: #{msg}"}
    catch
      kind, reason -> {kind, inspect(reason) |> String.slice(0, 110)}
    end

  IO.puts("#{label}\t#{inspect(result, limit: 4, printable_limit: 110) |> String.slice(0, 220)}")
end

id = Account.ID.new()
oid = Order.ID.new()
by = Blind.UserID.new()
at = Es.Event.At.now!()
name = Account.Name.new!("Имя")
ctx = Core.Context.new()
amount = Order.Amount.new!(10)
open = %Account.Cmd.Open{name: name, by: by, at: at}
blank = %Account{id: id}

run.("A1", fn -> S.Execute.a1_foreign_cmd(blank, %Order.Cmd.Place{amount: amount, by: by, at: at}) end)
run.("A2", fn -> S.Execute.a2_no_decide_clause(blank, by, at) end)
run.("A5a", fn -> S.Execute.a5a_state_typo(blank, open) end)
run.("A5c", fn -> S.Execute.a5c_event_typo(blank, open) end)
run.("D5", fn -> S.Execute.d5_payload_typo(open, blank) end)

run.("B1", fn -> S.DecideResult.b1_foreign_event_mod(%BadDecide{id: id}, open) end)
run.("B2", fn -> S.DecideResult.b2_foreign_payload(%BadDecide{id: id}, %Account.Cmd.Rename{name: name, by: by, at: at}) end)
run.("B3", fn -> S.DecideResult.b3_bare_mod_with_payload(%BadDecide{id: id}, %Account.Cmd.Close{by: by, at: at}) end)
run.("B4", fn -> S.DecideResult.b4_fold3_foreign_event_mod(blank, open) end)
run.("B5", fn -> S.DecideResult.b5_fold3_bare_mod(blank, open) end)

closed = Account.Event.Closed.new(id, Version.new(), by, at)
run.("C1 fold", fn -> S.Evolve.c1_fold_missing_clause(%BadEvolve{id: id}, closed) end)
run.("C1 execute", fn -> S.Evolve.c1_execute_missing_clause(%BadEvolve{id: id}, %Account.Cmd.Close{by: by, at: at}) end)
run.("C2a execute", fn -> S.Evolve.c2a_execute_payload_typo(%BadEvolve{id: id}, %Account.Cmd.Rename{name: name, by: by, at: at}) end)
run.("C3 fold", fn -> S.Evolve.c3_fold_bad(blank) end)
run.("C4 execute", fn -> S.Evolve.c4_execute_state_key_typo(%BadEvolveState{id: id}, %Account.Cmd.Rename{name: name, by: by, at: at}) end)
run.("C5 fold foreign event", fn -> Account.fold(blank, [Order.Event.Cancelled.new(oid, Version.new(), by, at)]) end)

payload = Account.Event.Opened.Payload.new(name)
run.("D2b", fn -> S.EventNew.d2b_foreign_aggregate_id_new(payload, by, at) end)
run.("D3b", fn -> S.EventNew.d3b_foreign_by_new(payload, id, at) end)

run.("E1b", fn -> S.Repo.e1b_foreign_id_new(ctx) end)
run.("E6", fn -> S.Repo.e6_get_many_foreign(oid, ctx) end)
run.("E3/E5 (БД)", fn -> S.Repo.e5_state_typo(id, ctx) end)

run.("F1b", fn -> S.Process.f1b_foreign_id_new(open, ctx) end)
run.("F2 (БД)", fn -> S.Process.f2_foreign_cmd(id, %Order.Cmd.Place{amount: amount, by: by, at: at}, ctx) end)

opened = Account.Event.Opened.new(payload, id, Version.new(), by, at)
run.("G1 direct", fn -> apply(BadProjection, :project, [closed]) end)
run.("G3a", fn -> BadProjection.project(opened) end)
run.("G4 (дерево/БД)", fn -> S.Projection.g4_await_foreign_id(oid) end)
run.("G4b", fn -> S.Projection.g4b_await_foreign_aggregate(oid) end)

pid = Parcel.ID.new()
lost = Parcel.Event.Lost.new(%Parcel.Event.Lost.Payload{note: "x"}, pid, Version.new(), by, at)
sent = Parcel.Event.Sent.new(%Parcel.Event.Sent.Payload{note: "x"}, pid, Version.new(), by, at)
run.("H1 dump", fn -> S.Codec.h1_dump_missing(lost) end)
sent_wire = InCodec.dump(sent)
lost_wire = %{sent_wire | "type" => "parcel.lost"}
run.("H1 load", fn -> InCodec.load(Parcel.Event, lost_wire) end)
run.("H2 load", fn -> InCodec.load(Parcel.Event, sent_wire) end)
opened_wire = InCodec.dump(opened)
run.("H3a", fn -> S.Codec.h3a_family_typo(opened_wire) end)
run.("H3b", fn -> S.Codec.h3b_mod_payload_typo(opened_wire) end)
run.("H3c", fn -> S.Codec.h3c_case_load(opened_wire) end)
run.("H4b", fn -> S.Codec.h4b_load_unknown_module(opened_wire) end)
run.("H5", fn -> S.Codec.h5_codec_dump_foreign(Order.Event.Cancelled.new(oid, Version.new(), by, at)) end)
run.("H6 dump cmd", fn -> InCodec.dump(open) end)

run.("I1", fn -> S.Cmd.i1_by_foreign(blank, name, oid, at) end)
run.("I2", fn -> S.Cmd.i2_at_datetime(blank, name, by) end)
run.("I3", fn -> S.Cmd.i3_name_string(blank, by, at) end)
run.("I4", fn -> S.Cmd.i4_decide_by_foreign(blank, name, oid, at) end)

run.("J1 execute", fn -> S.QcStyle.j1_execute(%QcStyle{id: id}, %Account.Cmd.Close{by: by, at: at}) end)

run.("X1", fn -> S.Extra.x1_execute_all_foreign_state(%Order{id: oid}, open) end)
run.("X2", fn -> S.Extra.x2_outbox_not_event() end)
{:ok, {account_events, _}} = Account.execute(blank, open)
run.("X5 outbox", fn -> Order.Outbox.from_events(account_events) |> elem(0) end)
run.("X5 store step", fn -> Core.Es.Store.append(Order.Event.Codec, account_events, ctx, fn _ -> nil end) end)

run.("X9b", fn -> Blind.S.Controller.x9b_untyped(oid, ctx) end)
run.("E3 outbox step", fn -> Account.Outbox.from_events([blank]) end)
