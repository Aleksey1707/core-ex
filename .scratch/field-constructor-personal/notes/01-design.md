# Field constructor + recursive personal places — shared design notes

Speс: `/home/aleksey/Projects/core-ex/.scratch/field-constructor-personal/spec.md`
Tickets: `/home/aleksey/Projects/core-ex/.scratch/field-constructor-personal/issues/`
Codebase map: `/home/aleksey/Projects/core-ex/.scratch/field-constructor-personal/notes/00-codebase-map.md`
Per-ticket notes: `.scratch/field-constructor-personal/notes/NN.md` (committed with the ticket)

These notes pin the cross-ticket decisions. Follow them; they exist so that eleven separate
implementers produce one coherent model. Where a note says MUST, a deviation breaks a later ticket.

## 1. Internal IR

New module `Core.Field` (`lib/core/field.ex`), struct (ticket 01, already merged):

```elixir
%Core.Field{
  name: atom(),                 # as declared
  wire: String.t(),             # wire key; default Atom.to_string(name)
  spec: spec(),
  optional?: boolean(),
  default: :none | {:default, term()},
  personal: nil | true | false, # declared flag only (nil = key absent)
  subject: nil | subject()      # declared subject only
}
```

`spec()` keeps today's tuple grammar (`Core.Codec.Field`), plus one wrapper for nested places and
View kinds:

```elixir
{:prim, mod} | {:enum, mod} | {:entity, mod} | {:union, mod} |
{:list, spec} | {:set, spec} | {:map, key_spec, value_spec} | {:type, atom} |
{:view, mod} | {:form, mod} | {:jsonb, mod} |
{:personal, spec}   # nested personal place (`list: [prim: X, personal: true]`, map value)
```

`subject()`: `:aggregate_id | {:payload, field_name} | {:local, field_name}`.

Roles: `:struct | :payload | :plugin | :view | :labels | :union`.

One grammar source: `Core.Field.declare!/3` delegates to the existing normalizer
(`Core.Codec.Field`, `Core.View.Opts.fields!/3` for the view role) — never copy kind parsing.

## 2. Metadata registry (ticket 01, merged)

`Core.Field.Meta` behaviour + one handler module per key under `lib/core/field/meta/`
(`optional`, `wire`, `default`, `personal`, `subject`). Handlers do **not** declare
`@behaviour Core.Field.Meta` (the reverse edge closes a compile/runtime cycle and breaks `mix xref`);
completeness is asserted by `test/core/field/meta_test.exs`. Unknown or role-forbidden key →
`CompileError` naming host and field.

Roles → allowed keys (MUST):

| key | struct | payload | plugin | view | labels | union |
|---|---|---|---|---|---|---|
| `optional` | ✓ | ✓ | ✓ (legacy `fields:`) | ✓ | ✓ | — |
| `wire` | ✓ | ✓ | ✓ (legacy) | ✓ | ✓ | — |
| `default` | ✓ (typed value) | ✗ | ✓ (legacy, wire literal) | ✓ | ✗ | — |
| `personal` | ✓ | ✓ | ✗ | ✗ | ✓ | — |
| `subject` | ✓ | ✓ | ✗ | ✗ | ✗ | — |

`destroyable:` is removed in ticket 02; the rejection text keeps the word `destroyable:` and says
that the ПДн place is now `personal: true` and the read type adds `Destroyed`.

## 3. Introspection protocol

Every declarative host generates (ticket 01 does Struct / Payload / ValueChanged; 03 adds Union,
06 adds View where it has fields):

```elixir
@doc false
@spec __core_fields__() :: [Core.Field.t()]
def __core_fields__, do: @core_fields
```

`Core.Field.introspect/1` is the only reader; no consumer may test which `use` built the module.
Old attributes (`__struct_fields__`, `__es_payload_fields__`, `__es_value_changed__`,
`declared_fields/1`, `__codec_fields`/`__codec_variants`) stay until ticket 10 and MUST agree with
`__core_fields__/0`.

`Core.Union` (ticket 03) generates `__core_variants__/0`, `types/0`, `variant/1`; address forms stay
exactly as today (`Core.Codec.Plugin.Variants`): `"tag"`, `{"tag", key: value}`, `[key: value]`.

## 4. Personal place resolution (single walker)

One walker (in `Core.Field`, helpers may live in `Core.Es.Personal.Plan`, but never two walks). A
**place** is a value position whose value is sealed as one ciphertext.

1. `personal: true` on a field → whole field value is one place; do not descend.
2. spec `{:personal, inner}` (nested `personal: true`) → same for that nested position.
3. `{:prim, mod}` with `mod.__domain_personal__()` → place (leaf).
4. `{:entity, mod}` with `__core_fields__/0` → descend with the field wire key appended.
5. `{:entity, mod}` without `__core_fields__/0` (opaque) → `personal: true` seals it,
   `personal: false` declares "no ПДн inside"; neither → `CompileError`.
6. `{:union, _}` → opaque for the walker: explicit `personal: true` or `false` required;
   `personal: true` seals the whole variant wire value.
7. `{:list, inner}` → descend per element (`:each` step), place per element.
8. `{:set, inner}` / `{:map, key, value}` → if the element (or key) resolves to a place,
   **escalate**: whole container is one place (`%Destroyed{}` on the container in read types).
   Otherwise descend into map values per `:each`.
9. `{:enum, _}`, `{:type, _}` → never personal by themselves.
10. `personal: false` never demotes a place made personal by rules 1–3.

`subject:` does not create a place. Nearest `subject:` wins. Root default `:aggregate_id`.
`CompileError`: `subject:` in a subtree with no personal place; `subject:` re-defined under a
`personal: true` boundary; subject not a UUID Prim (`Core.Es.Event.Payload.uuid_prim?/1`) or itself
personal; required personal place under an optional subject.

## 5. Read type / write type

`t()` (read): at every personal place add `| Core.Es.Personal.Destroyed.t()`; `optional: true` adds
`| nil` after it. `write_t()` (write): same shape without `Destroyed`:
- `{:entity, mod}` → `mod.write_t()` if exported, else `mod.t()`;
- `{:union, fam}` → union of `Variant.write_t()/t()` per variant (Prim variant → its `t()`);
- `{:list, inner}` → `[projected]`; `{:set, inner}` → `MapSet.t(projected)`;
- `{:map, k, v}` → `%{optional(k_projected) => v_projected}`;
- `{:prim | :enum, mod}` → `mod.t()`; `{:type, t}` → scalar type.

Every declarative struct emits both; with no personal places `@type write_t :: t()`.
`Payload` emits `t()` and `write_t()`; `new/N` takes write types and rejects `%Destroyed{}`
recursively; `draft/1` accepts the write projection. `Core.Struct` has no runtime constructor: the
write type plus consumers carry the protection.

## 6. Personal plan and paths

`Core.Es.Event.Codec` generates `__es_personal__/0` (replaces `__es_subjects__/0`):

```elixir
%{Event.Created => [%{path: [:metadata], subject: :aggregate_id},
                    %{path: [:steps, :each, :recipient], subject: :aggregate_id}]}
```

- `path` steps: wire keys as atoms and `:each` for list/map-value elements (declaration-level).
- `subject`: `:aggregate_id` or `{:path, [step]}` — concrete declaration path from the payload root
  (wire keys + `:each`), resolved at plan build time. A local sibling subject inside
  `steps: [list: [entity: Step]]` becomes `{:path, [:steps, :each, :owner_id]}`.
- `Core.Es.Personal.Plan` owns building entries from `[%Core.Field{}]`, subject resolution and
  `entries/2`, `place?/2`. Nothing else reads `__es_personal__/0` directly except `Wire`, the case
  modules and the fixtures generator.

## 7. Seal / open walk and AAD

`Core.Es.Personal.Wire` becomes recursive, driven by the plan of the event module:

- Write: `dump` leaves personal places open as `%Core.Es.Personal.Marker{}` at the exact wire
  position (nested maps and lists). `Wire.seal_payloads/1` walks the payload, collects every marker
  with its concrete path, seals all in one `Port.seal/1`, substitutes `%{"$pd" => base64}`.
- AAD: `Port.address([event_id | concrete_path])`, parts are strings: wire keys, list indexes,
  map keys (wire string). One seal call per transaction batch, one open call per read batch.
- Read: one recursive scan for `%{"$pd" => sealed}`, one `Port.open/1` batch, substitute decoded
  JSON (or keep `{"$pd": null}` as the destroyed marker for `load`). `:unreadable` outcome kept.

## 8. Destroyed value at load

At a personal place: `%{"$pd" => nil}` → `%Core.Es.Personal.Destroyed{}` **before** kind/variant
dispatch (for `union:` with `personal: true` — before variant selection, manual codec not called).
Outside a place: `%{"$pd" => nil}` → `:invalid_value`; `%{"$pd" => "<string>"}` anywhere →
`:sealed_personal_value` (`ns: :codec`). `nil` of an optional personal field stays `nil`.
Errors raised while loading a personal place redact `detail` and the whole cause chain while keeping
the error path (`field`, `index`, `key`).

## 9. CompileError texts

Texts are contract. Prefixes: `Struct: fields: <field>: …`, `Es.Event.Payload: fields: <field>: …`,
`Codec.Plugin: fields: …`, `Codec.Plugin: variants: …`, `Union: variants: …`, `View: fields: …`.
Reuse existing wording wherever the check already existed.

## 10. Migration discipline (expand / contract)

- Ticket 01 (done) is expand: IR + registry + `__core_fields__/0` beside old paths.
- Tickets 02–09 migrate one role at a time; each updates its own declaration-seam tests and keeps
  data-path tests green.
- Ticket 10 removes old attributes and `%Core.Codec.Field{}` paths.
- No history rewriting; old open rows read as open values.

## 11. Existing consumers of `__es_subjects__/0` (must migrate with the plan)

- `lib/core/es/event/codec.ex:320` generator, `subjects/1` at `:412`.
- `lib/core/es/aggregate/repo/pg/snapshot.ex:52` `opts!/3`, `:77` `sealed!/2`.
- `lib/core/es/aggregate/repo/pg.ex:370`, `:101-107`.
- `lib/core/es/aggregate/process.ex:250` (`personal:` of the process).
- `lib/core/es/projection.ex:427-452` `personal!/*`.
- `lib/core/es/aggregate/load/engine.ex:295-299` `destroyed_value?/2` (top level only).
- `lib/core/es/personal/test.ex:137` `subject_fields/1`; `projection_case.ex:387` `subject_wires/1`.
- `test/core/es/event/codec_personal_test.exs` (describe on `__es_subjects__/0`).

`Core.Es.Aggregate.Process` and `Core.Es.Projection` must decide "has personal places" from the
plan, not from a non-empty subjects map.

## 12. Verification

- `MIX_TEST_PARTITION=<unique>` per worktree (bases `core_test1..4` already migrated).
- `make DOCKER=true` (infra shared; never `make infra-up` from a worktree).
- Full `make` in the foreground, timeout 600000. Dialyzer PLT is per-worktree: tickets 10/11 run
  full `make`; earlier tickets run every step except `dialyzer` unless the ticket changes public
  typespecs.
