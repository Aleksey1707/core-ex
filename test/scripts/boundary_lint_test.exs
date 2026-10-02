defmodule BoundaryLintTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/boundary_lint.exs", __DIR__)
  @layout "deps/core/docs/rules/app/10-architecture.md"
  @repos "deps/core/docs/rules/13-repos.md"

  test "чистое дерево — код 0", %{tmp_dir: dir} do
    write(dir, "lib/my_app.ex", "defmodule MyApp do\nend\n")
    write(dir, "lib/my_app/domain/orders.ex", "defmodule MyApp.Domain.Orders do\nend\n")
    write(dir, "test/my_app/orders_test.exs", "defmodule MyApp.Elsewhere.OrdersTest do\nend\n")

    assert {out, 0} = lint(dir)
    assert out =~ "нарушений нет"
  end

  test "путь ≠ имя модуля", %{tmp_dir: dir} do
    write(dir, "lib/my_app/orders.ex", "\ndefmodule MyApp.Order do\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/orders.ex:2: "
    assert out =~ "lib/my_app/order.ex"
    assert out =~ "правила — #{@layout}"
  end

  test "два верхнеуровневых модуля в файле", %{tmp_dir: dir} do
    write(dir, "lib/my_app/order.ex", """
    defmodule MyApp.Order do
    end

    defmodule MyApp.OrderLine do
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/order.ex:4: "
    assert out =~ "lib/my_app/order_line.ex"
    refute out =~ "lib/my_app/order.ex:1: "
  end

  test "вложенный модуль и модуль под `if` следуют правилу родителя", %{tmp_dir: dir} do
    write(dir, "lib/my_app/order.ex", """
    defmodule MyApp.Order do
      defmodule Line do
      end
    end
    """)

    write(dir, "lib/my_app/optional.ex", """
    if Code.ensure_loaded?(Jason) do
      defmodule MyApp.Optional do
      end
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "аббревиатура в корне — без нарушения", %{tmp_dir: dir} do
    write(dir, "lib/app_a/http_client.ex", "defmodule AppA.HTTPClient do\nend\n")

    assert {_out, 0} = lint(dir)
  end

  test "каталог `./lib` — тот же `lib`", %{tmp_dir: dir} do
    write(dir, "lib/my_app/order.ex", "defmodule MyApp.Order do\nend\n")

    assert {_out, 0} = lint(dir, ["./lib"])
  end

  test "mix-таска — по конвенции Mix", %{tmp_dir: dir} do
    write(dir, "lib/mix/tasks/outbox.requeue.ex", "defmodule Mix.Tasks.Outbox.Requeue do\nend\n")
    write(dir, "lib/mix/tasks/outbox/drop.ex", "defmodule Mix.Tasks.Outbox.Drop do\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "lib/mix/tasks/outbox/drop.ex:1: "
    assert out =~ "lib/mix/tasks/outbox.drop.ex"
    refute out =~ "outbox.requeue.ex:"
  end

  test "маркер со ссылкой на DEBT.md гасит нарушение своего правила", %{tmp_dir: dir} do
    write(dir, "lib/my_app/orders.ex", """
    # boundary-lint: allow module-path — DEBT.md, «Файл не по имени модуля»
    defmodule MyApp.Order do
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "маркер без ссылки на раздел DEBT.md или не над defmodule не гасит ничего", %{tmp_dir: dir} do
    write(dir, "lib/my_app/orders.ex", """
    # boundary-lint: allow module-path
    defmodule MyApp.Order do
    end
    """)

    write(dir, "lib/my_app/lines.ex", """
    # boundary-lint: allow module-path — DEBT.md
    defmodule MyApp.Line do
    end
    """)

    write(dir, "lib/my_app/items.ex", """
    @x 1 # boundary-lint: allow module-path — DEBT.md, «Файл не по имени модуля»
    defmodule MyApp.Item do
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/orders.ex:2: "
    assert out =~ "lib/my_app/lines.ex:2: "
    assert out =~ "lib/my_app/items.ex:2: "
  end

  test "маркер гасит только свой модуль и своё правило", %{tmp_dir: dir} do
    write(dir, "lib/my_app/orders.ex", """
    # boundary-lint: allow module-path — DEBT.md, «Файл не по имени модуля»
    defmodule MyApp.Order do
      @repo Application.compile_env(:my_app, MyApp.Order.Repo)
    end

    defmodule MyApp.OrderLine do
    end
    """)

    write(dir, "lib/my_app/line.ex", """
    # boundary-lint: allow other-rule — DEBT.md, «Другое»
    defmodule MyApp.Lines do
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/orders.ex:3: `Application.compile_env`"
    assert out =~ "lib/my_app/orders.ex:6: "
    assert out =~ "lib/my_app/line.ex:2: "
    refute out =~ "lib/my_app/orders.ex:2: "
    assert out =~ "нарушений — 3"
    assert out =~ @layout
    assert out =~ @repos
  end

  test "DI-нарушение ловится в lib и test", %{tmp_dir: dir} do
    write(dir, "lib/my_app/order.ex", """
    defmodule MyApp.Order do
      @repo Application.compile_env(:my_app, MyApp.Order.Repo)
    end
    """)

    write(dir, "test/my_app/order_test.exs", """
    defmodule MyApp.OrderTest do
      @repo Application.compile_env!(:my_app, MyApp.Order.ReadRepo)
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/order.ex:2: `Application.compile_env` на MyApp.Order.Repo"
    assert out =~ "test/my_app/order_test.exs:2: `Application.compile_env!` на MyApp.Order.ReadRepo"
    assert out =~ "правила — #{@repos}"
    refute out =~ @layout
  end

  test "`Common` — bc-root одно на часть контекста, на первом модуле по пути", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/common/order.ex", """
    defmodule MyApp.Domain.Orders.Common.Order do
      defmodule ID do
      end
    end
    """)

    write(
      dir,
      "lib/my_app/domain/orders/common/order/repo.ex",
      "defmodule MyApp.Domain.Orders.Common.Order.Repo do\nend\n"
    )

    assert {out, 1} = lint(dir)

    assert out =~
             "lib/my_app/domain/orders/common/order.ex:1: `MyApp.Domain.Orders.Common` — общая часть контекста"

    assert out =~ "в его каталоге `MyApp.Domain.Orders.<Aggregate>`"
    assert out =~ "прочих модулей namespace с тем же нарушением: 2, правка одна"
    assert out =~ "правила — #{@layout}"
    assert out =~ "нарушений — 1"
  end

  test "срез на уровне контекста — bc-root на usecases по сценарию; `<Aggregate>.Usecases` модулем — не срез",
       %{tmp_dir: dir} do
    write_index(dir, "Orders")

    for {path, module} <- [
          {"lib/my_app/domain/orders/admin/usecases/order.ex", "MyApp.Domain.Orders.Admin.Usecases.Order"},
          {"lib/my_app/domain/orders/admin/usecases/cart.ex", "MyApp.Domain.Orders.Admin.Usecases.Cart"},
          {"lib/my_app/domain/orders/order/usecases.ex", "MyApp.Domain.Orders.Order.Usecases"},
          {"lib/my_app/domain/orders/order/usecases/query.ex", "MyApp.Domain.Orders.Order.Usecases.Query"}
        ] do
      write(dir, path, "defmodule #{module} do\nend\n")
    end

    assert {out, 1} = lint(dir)
    assert out =~ "admin/usecases/cart.ex:1: `MyApp.Domain.Orders.Admin` — срез на уровне контекста"
    assert out =~ "`MyApp.Domain.Orders.<Aggregate>.Admin.Usecases`"
    assert out =~ "прочих модулей namespace с тем же нарушением: 1, правка одна"
    refute out =~ "Order.Usecases"
    assert out =~ "нарушений — 1"
  end

  test "вертикаль: каталог агрегата и актора, values, errors, read-модель и операция по назначению, reactions",
       %{tmp_dir: dir} do
    write_index(dir, "Orders")

    for {path, module} <- [
          {"lib/my_app/domain/orders/order.ex", "MyApp.Domain.Orders.Order"},
          {"lib/my_app/domain/orders/order/event/placed.ex", "MyApp.Domain.Orders.Order.Event.Placed"},
          {"lib/my_app/domain/orders/order/repo/pg.ex", "MyApp.Domain.Orders.Order.Repo.Pg"},
          {"lib/my_app/domain/orders/order/usecases.ex", "MyApp.Domain.Orders.Order.Usecases"},
          {"lib/my_app/domain/orders/order/client/usecases.ex", "MyApp.Domain.Orders.Order.Client.Usecases"},
          {"lib/my_app/domain/orders/order/admin/read_repo.ex", "MyApp.Domain.Orders.Order.Admin.ReadRepo"},
          {"lib/my_app/domain/orders/order/admin/view.ex", "MyApp.Domain.Orders.Order.Admin.View"},
          {"lib/my_app/domain/orders/values/user_id.ex", "MyApp.Domain.Orders.Values.UserID"},
          {"lib/my_app/domain/orders/errors.ex", "MyApp.Domain.Orders.Errors"},
          {"lib/my_app/domain/orders/checkout/client/usecases.ex", "MyApp.Domain.Orders.Checkout.Client.Usecases"},
          {"lib/my_app/domain/orders/reactions/payments.ex", "MyApp.Domain.Orders.Reactions.Payments"}
        ] do
      write(dir, path, "defmodule #{module} do\nend\n")
    end

    for {path, module} <- [
          {"lib/my_app/domain/orders/order/projection.ex", "MyApp.Domain.Orders.Order.Projection"},
          {"lib/my_app/domain/orders/backlog/projection.ex", "MyApp.Domain.Orders.Backlog.Projection"}
        ] do
      write(dir, path, "defmodule #{module} do\n  use Core.Es.Projection, name: \"x\"\nend\n")
    end

    assert {out, 0} = lint(dir)
    assert out =~ "нарушений нет"
  end

  test "маркер bc-root над любым модулем части гасит её нарушение, над чужой частью — нет", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/common/order.ex", "defmodule MyApp.Domain.Orders.Common.Order do\nend\n")

    write(dir, "lib/my_app/domain/orders/common/order/repo.ex", """
    # boundary-lint: allow bc-root — DEBT.md, «Common до переезда»
    defmodule MyApp.Domain.Orders.Common.Order.Repo do
    end
    """)

    write(dir, "lib/my_app/domain/orders/admin/usecases/order.ex", """
    # boundary-lint: allow module-path — DEBT.md, «Другое»
    defmodule MyApp.Domain.Orders.Admin.Usecases.Order do
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "admin/usecases/order.ex:2: `MyApp.Domain.Orders.Admin` — срез"
    refute out =~ "Common"
    assert out =~ "нарушений — 1"
  end

  test "проекция — только `<BC>.<ReadModel>.Projection`, проектор запрещён", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    for {path, module} <- [
          {"lib/my_app/domain/orders/projection.ex", "MyApp.Domain.Orders.Projection"},
          {"lib/my_app/domain/orders/order/projection.ex", "MyApp.Domain.Orders.Order.Projection"},
          {"lib/my_app/domain/orders/backlog/projection_v2.ex", "MyApp.Domain.Orders.Backlog.ProjectionV2"},
          {"lib/my_app/domain/orders/order/admin/projection.ex", "MyApp.Domain.Orders.Order.Admin.Projection"},
          {"lib/my_app/domain/orders/order/writer.ex", "MyApp.Domain.Orders.Order.Writer"}
        ] do
      write(dir, path, "defmodule #{module} do\n  use Core.Es.Projection, name: \"x\"\nend\n")
    end

    write(dir, "lib/my_app/domain/orders/order/read_repo/pg/projector.ex", """
    defmodule MyApp.Domain.Orders.Order.ReadRepo.Pg.Projector do
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/projection.ex:1: `MyApp.Domain.Orders.Projection` — проекция вне"
    assert out =~ "lib/my_app/domain/orders/order/admin/projection.ex:1: "
    assert out =~ "lib/my_app/domain/orders/order/writer.ex:1: "
    assert out =~ "Pg.Projector` — отдельный модуль записи"
    assert out =~ "deps/core/docs/rules/app/13-repos.md"
    assert out =~ "нарушений — 4"
  end

  test "корень web: закрытый список и поверхности с `ApiSpec`", %{tmp_dir: dir} do
    write(dir, "lib/my_app.ex", "defmodule MyApp do\nend\n")

    for {path, module} <- [
          {"lib/my_app_web.ex", "MyAppWeb"},
          {"lib/my_app_web/endpoint.ex", "MyAppWeb.Endpoint"},
          {"lib/my_app_web/error_json.ex", "MyAppWeb.ErrorJSON"},
          {"lib/my_app_web/params/page.ex", "MyAppWeb.Params.Page"},
          {"lib/my_app_web/public/v1/api_spec.ex", "MyAppWeb.Public.V1.ApiSpec"},
          {"lib/my_app_web/public/v1/order/controller.ex", "MyAppWeb.Public.V1.Order.Controller"},
          {"lib/my_app_web/partner/api_spec.ex", "MyAppWeb.Partner.ApiSpec"},
          {"lib/my_app_web/helper/projection.ex", "MyAppWeb.Helper.Projection"},
          {"lib/my_app_web/helper/deep/api_spec.ex", "MyAppWeb.Helper.Deep.ApiSpec"},
          {"lib/my_app_web/admin/v1/user/controller.ex", "MyAppWeb.Admin.V1.User.Controller"}
        ] do
      write(dir, path, "defmodule #{module} do\nend\n")
    end

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app_web/helper/deep/api_spec.ex:1: `MyAppWeb.Helper` — не часть корня web"
    assert out =~ "прочих модулей namespace с тем же нарушением: 1, правка одна"
    refute out =~ "helper/projection.ex"
    assert out =~ "lib/my_app_web/admin/v1/user/controller.ex:1: `MyAppWeb.Admin`"
    assert out =~ "lib/my_app_web/partner/api_spec.ex:1: `MyAppWeb.Partner`"
    assert out =~ "`MyAppWeb.Partner.ApiSpec` — спецификация на версию: `MyAppWeb.Partner.<Version>.ApiSpec`"
    assert out =~ "deps/core/docs/rules/app/15-web-api.md"
    assert out =~ "нарушений — 3"
  end

  test "маркер гасит web-root своего модуля", %{tmp_dir: dir} do
    write(dir, "lib/my_app.ex", "defmodule MyApp do\nend\n")

    write(dir, "lib/my_app_web/helper.ex", """
    # boundary-lint: allow web-root — DEBT.md, «Хелпер в корне web»
    defmodule MyAppWeb.Helper do
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "projection-layout: алиас в `use`, вложенный модуль, глубже каталога, `quote`, `Projector` вне ReadRepo",
       %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/projection.ex", """
    defmodule MyApp.Domain.Orders.Projection do
      alias Core.Es
      use Es.Projection, name: "orders"
    end
    """)

    write(dir, "lib/my_app/domain/orders/order/read_repo/pg.ex", """
    defmodule MyApp.Domain.Orders.Order.ReadRepo.Pg do
      defmodule Projection do
        use Core.Es.Projection, name: "x"
      end

      defmodule Projector do
      end
    end
    """)

    write(dir, "lib/my_app/projection_kit.ex", """
    defmodule MyApp.ProjectionKit do
      defmacro __using__(opts), do: quote(do: use(Core.Es.Projection, unquote(opts)))
    end
    """)

    write(dir, "lib/my_app/domain/orders/order/projector.ex", "defmodule MyApp.Domain.Orders.Order.Projector do\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "orders/projection.ex:1: `MyApp.Domain.Orders.Projection` — проекция вне"
    assert out =~ "read_repo/pg.ex:2: `MyApp.Domain.Orders.Order.ReadRepo.Pg.Projection` — проекция вне"
    assert out =~ "read_repo/pg.ex:6: `MyApp.Domain.Orders.Order.ReadRepo.Pg.Projector` — отдельный модуль"
    assert out =~ "нарушений — 3"
  end

  test "web-root: вложенные модули, подсказка про `ApiSpec` поверхности, чужой `OtherWeb` — не корень web",
       %{tmp_dir: dir} do
    write(dir, "lib/my_app.ex", "defmodule MyApp do\nend\n")

    write(dir, "lib/my_app_web/public/v1.ex", """
    defmodule MyAppWeb.Public.V1 do
      defmodule ApiSpec do
      end
    end
    """)

    write(
      dir,
      "lib/my_app_web/public/v1/order/controller.ex",
      "defmodule MyAppWeb.Public.V1.Order.Controller do\nend\n"
    )

    write(dir, "lib/my_app_web.ex", "defmodule MyAppWeb do\n  defmodule Helper do\n  end\nend\n")
    write(dir, "lib/my_app_web/api/api_spec.ex", "defmodule MyAppWeb.Api.ApiSpec do\nend\n")
    write(dir, "lib/other_web/digest.ex", "defmodule OtherWeb.Digest do\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app_web.ex:2: `MyAppWeb.Helper`"
    assert out =~ "`MyAppWeb.Api.ApiSpec` — спецификация на версию: `MyAppWeb.Api.<Version>.ApiSpec`"
    refute out =~ "MyAppWeb.Public`"
    refute out =~ "OtherWeb"
    assert out =~ "нарушений — 2"
  end

  test "DI через `alias … as:`, `defprotocol` по пути", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/order/client/usecases.ex", """
    defmodule MyApp.Domain.Orders.Order.Client.Usecases do
      alias MyApp.Domain.Orders.Order.Repo, as: OrderRepo
      @repo Application.compile_env(:my_app, OrderRepo)
    end
    """)

    write(dir, "lib/my_app/proto/wrong.ex", "defprotocol MyApp.Renderable do\n  def render(x)\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "order/client/usecases.ex:3: `Application.compile_env` на OrderRepo"
    assert out =~ "lib/my_app/proto/wrong.ex:1: модуль `MyApp.Renderable` не по пути"
    assert out =~ "нарушений — 2"
  end

  test "маркер: `DEBT.md` целым словом, keyword-форма модуля; дубли строки сворачиваются", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/wrong.ex", """
    # boundary-lint: allow module-path — see NOT_DEBT.md, «что угодно»
    defmodule MyApp.Other do
    end
    """)

    write(dir, "lib/my_app/domain/orders/projection.ex", """
    # boundary-lint: allow projection-layout — DEBT.md, «Проекция контекста»
    defmodule MyApp.Domain.Orders.Projection,
      do: use(Core.Es.Projection, name: "orders")
    """)

    write(dir, "lib/my_app/domain/orders/order.ex", """
    defmodule MyApp.Domain.Orders.Order do
      @repos {Application.compile_env(:my_app, MyApp.Order.Repo), Application.compile_env(:my_app, MyApp.Order.Repo)}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/wrong.ex:2: модуль `MyApp.Other` не по пути"
    refute out =~ "orders/projection.ex"
    assert out =~ "orders/order.ex:2: `Application.compile_env` на MyApp.Order.Repo"
    assert out =~ "нарушений — 2"
  end

  test "файл, который не разбирается, — код 2 с путём", %{tmp_dir: dir} do
    write(dir, "lib/my_app/broken.ex", "defmodule MyApp.Broken do\n  def x(, do: 1\nend\n")

    assert {out, 2} = lint(dir)
    assert out =~ "lib/my_app/broken.ex:"
    assert out =~ "не разобран"
  end

  test "вторая итерация: маркер над `defprotocol`, DI `Repo.Pg` через `as:`, дубли web-root, подсказки ApiSpec",
       %{tmp_dir: dir} do
    write(dir, "lib/my_app.ex", "defmodule MyApp do\nend\n")
    write_index(dir, "Orders")

    write(dir, "lib/my_app/proto/printable.ex", """
    # boundary-lint: allow module-path — DEBT.md, «Протокол не по пути»
    defprotocol MyApp.Printable do
      def print(x)
    end
    """)

    write(dir, "lib/my_app/domain/orders/projection.ex", """
    defmodule MyApp.Domain.Orders.Projection do
      use Core.Es.Projection, name: "orders"
    end
    """)

    write(dir, "lib/my_app/domain/orders/order/client/usecases.ex", """
    defmodule MyApp.Domain.Orders.Order.Client.Usecases do
      alias MyApp.Domain.Orders.Order.Repo, as: OrderRepo
      @impl_module Application.compile_env(:my_app, OrderRepo.Pg)
    end
    """)

    write(dir, "lib/my_app_web/helper.ex", """
    defmodule MyAppWeb.Helper do
      defmodule A do
      end

      defmodule B do
      end
    end
    """)

    write(dir, "lib/my_app_web/api_spec.ex", "defmodule MyAppWeb.ApiSpec do\nend\n")
    write(dir, "lib/my_app_web/tools/deep/api_spec.ex", "defmodule MyAppWeb.Tools.Deep.ApiSpec do\nend\n")

    assert {out, 1} = lint(dir)
    refute out =~ "Printable"
    assert out =~ "projection.ex:1: `MyApp.Domain.Orders.Projection` — проекция вне"
    refute out =~ "OrderRepo"
    assert out =~ "helper.ex:1: `MyAppWeb.Helper`"
    refute out =~ "helper.ex:2"
    assert out =~ "`ApiSpec` — у версии поверхности: `MyAppWeb.<Api>.<Version>.ApiSpec`"
    assert out =~ "tools/deep/api_spec.ex:1: `MyAppWeb.Tools`"
    refute out =~ "MyAppWeb.Tools.<Version>"
    assert out =~ "нарушений — 4"
  end

  test "событие и команда, вложенные в семейство, — module-path со своим файлом", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/order/event.ex", """
    defmodule MyApp.Domain.Orders.Order.Event do
      defmodule Placed do
        defmodule Payload do
        end
      end
    end
    """)

    write(dir, "lib/my_app/domain/orders/order/cmd.ex", """
    defmodule MyApp.Domain.Orders.Order.Cmd do
      defmodule Place do
      end
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "order/event.ex:2: `MyApp.Domain.Orders.Order.Event.Placed` вложен в семейство"
    assert out =~ "lib/my_app/domain/orders/order/event/placed.ex"
    assert out =~ "order/cmd.ex:2: `MyApp.Domain.Orders.Order.Cmd.Place` вложен в семейство"
    refute out =~ "Payload"
    assert out =~ "нарушений — 2"
  end

  test "семейство событий: Prim агрегата `Event`, модуль вне `Domain` и кодек — не члены семейства", %{tmp_dir: dir} do
    write_index(dir, "Calendar")

    write(dir, "lib/my_app/domain/calendar/event.ex", """
    defmodule MyApp.Domain.Calendar.Event do
      defmodule ID do
      end
    end
    """)

    write(dir, "lib/my_app/domain/calendar/entry/event.ex", """
    defmodule MyApp.Domain.Calendar.Entry.Event do
      defmodule Codec do
      end
    end
    """)

    write(dir, "lib/my_app/telemetry/event.ex", """
    defmodule MyApp.Telemetry.Event do
      defmodule Handler do
      end
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "каталог контекста без модуля-оглавления", %{tmp_dir: dir} do
    write(dir, "lib/my_app/domain/orders/order.ex", "defmodule MyApp.Domain.Orders.Order do\nend\n")
    write(dir, "lib/my_app/domain/billing/invoice.ex", "defmodule MyApp.Domain.Billing.Invoice do\nend\n")
    write_index(dir, "Billing")

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/:0: "
    assert out =~ "lib/my_app/domain/orders.ex"
    assert out =~ "нарушений — 1"
    assert out =~ "правила — #{@layout}"
  end

  test "оглавление без `use Boundary` — bc-index на оглавлении; `use` через алиас — корень границы", %{tmp_dir: dir} do
    write(dir, "lib/my_app/domain/orders.ex", """
    defmodule MyApp.Domain.Orders do
      @moduledoc "Заказы."
    end
    """)

    write(dir, "lib/my_app/domain/orders/order.ex", "defmodule MyApp.Domain.Orders.Order do\nend\n")

    write(dir, "lib/my_app/domain/billing.ex", """
    defmodule MyApp.Domain.Billing do
      alias Boundary, as: B
      use B, deps: [], exports: []
    end
    """)

    write(dir, "lib/my_app/domain/billing/invoice.ex", "defmodule MyApp.Domain.Billing.Invoice do\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders.ex:1: `MyApp.Domain.Orders` — оглавление без `use Boundary`"
    assert out =~ "нарушений — 1"
  end

  test "модуль-оглавление с аббревиатурой в имени контекста — без нарушения", %{tmp_dir: dir} do
    write_index(dir, "CRM")
    write(dir, "lib/my_app/domain/crm/lead.ex", "defmodule MyApp.Domain.CRM.Lead do\nend\n")

    assert {_out, 0} = lint(dir)
  end

  test "маркер в модуле контекста или в оглавлении гасит bc-index, маркер чужого правила — нет", %{tmp_dir: dir} do
    write(dir, "lib/my_app/domain/orders/order.ex", """
    # boundary-lint: allow bc-index — DEBT.md, «Контекст без оглавления»
    defmodule MyApp.Domain.Orders.Order do
    end
    """)

    write(dir, "lib/my_app/domain/billing/invoice.ex", """
    # boundary-lint: allow module-path — DEBT.md, «Файл не по имени модуля»
    defmodule MyApp.Domain.Billing.Invoice do
    end
    """)

    write(dir, "lib/my_app/domain/users.ex", """
    # boundary-lint: allow bc-index — DEBT.md, «Оглавление без границы»
    defmodule MyApp.Domain.Users do
    end
    """)

    write(dir, "lib/my_app/domain/users/user.ex", "defmodule MyApp.Domain.Users.User do\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/billing/:0: "
    assert out =~ "нарушений — 1"
  end

  defp write(dir, path, source) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp write_index(dir, bc),
    do:
      write(
        dir,
        "lib/my_app/domain/#{Macro.underscore(bc)}.ex",
        "defmodule MyApp.Domain.#{bc} do\n  use Boundary, deps: [], exports: []\nend\n"
      )

  defp lint(dir, dirs \\ ["lib", "test"]) do
    File.mkdir_p!(Path.join(dir, "test"))
    System.cmd("elixir", [@script, "--consumer" | dirs], cd: dir, env: bare_env(), stderr_to_stdout: true)
  end

  # Скрипту нужны только `elixir` в PATH и UTF-8 локаль: остальное окружение прогона не наследуется.
  defp bare_env do
    for {name, _value} <- System.get_env(), name not in ~w(PATH HOME LANG LC_ALL LC_CTYPE), into: %{}, do: {name, nil}
  end
end
