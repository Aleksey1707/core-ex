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

  test "`Common` → срез своего контекста по полному имени", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/common/order/projection.ex", """
    defmodule MyApp.Domain.Orders.Common.Order.Projection do
      def run, do: MyApp.Domain.Orders.Admin.Order.Projector.project()
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/common/order/projection.ex:2: "
    assert out =~ "MyApp.Domain.Orders.Admin.Order.Projector"
    assert out =~ "правила — #{@layout}"
  end

  test "`Common` → срез своего контекста через алиас; алиас от `__MODULE__` перекрывает прежний", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/common/order.ex", """
    defmodule MyApp.Domain.Orders.Common.Order do
      alias MyApp.Domain.Orders.Admin.Usecases
      alias MyApp.Domain.Orders.Admin.{Item, Line}
      alias __MODULE__.Line
      alias __MODULE__.{Item}

      def run, do: {Usecases.Order.run(), Line.new(), Item.new()}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/common/order.ex:7: "
    assert out =~ "MyApp.Domain.Orders.Admin.Usecases.Order"
    assert out =~ "нарушений — 1"
  end

  test "контекст → срез чужого контекста через многоимённый алиас", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/client/usecases/order.ex", """
    defmodule MyApp.Domain.Orders.Client.Usecases.Order do
      alias MyApp.Domain.Billing.{Admin, Common}
      alias MyApp.Domain.Billing.Admin.Usecases.Invoice, as: AdminInvoice
      require MyApp.Domain.Billing.Admin.Macros, as: AdminMacros

      def run do
        Common.Invoice.Repo.get()
        Admin.Usecases.Invoice.run()
        AdminInvoice.run()
        AdminMacros.m()
      end
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/client/usecases/order.ex:4: "
    assert out =~ "lib/my_app/domain/orders/client/usecases/order.ex:8: "
    assert out =~ "lib/my_app/domain/orders/client/usecases/order.ex:9: "
    assert out =~ "lib/my_app/domain/orders/client/usecases/order.ex:10: "
    assert out =~ "MyApp.Domain.Billing.Admin.Usecases.Invoice"
    assert out =~ "нарушений — 4"
  end

  test "`Common` → `Common` чужого контекста, срез → свои `Common` и срез, web → любой срез — без нарушений",
       %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/common/order.ex", """
    defmodule MyApp.Domain.Orders.Common.Order do
      alias MyApp.Domain.Billing

      def run, do: Billing.Common.Invoice.new()
    end
    """)

    write(dir, "lib/my_app/domain/orders/admin/usecases/order.ex", """
    defmodule MyApp.Domain.Orders.Admin.Usecases.Order do
      alias MyApp.Domain.Orders.{Admin, Common}

      def run, do: {Common.Order.new(), Admin.Usecases.Cart.run(), __MODULE__}
    end
    """)

    write(dir, "lib/my_app_web/fallback_controller.ex", """
    defmodule MyAppWeb.FallbackController do
      def index, do: MyApp.Domain.Billing.Admin.Usecases.Invoice.run()
    end
    """)

    write(dir, "test/my_app/domain/orders/common/order_test.exs", """
    defmodule MyApp.Domain.Orders.Common.OrderTest do
      def run, do: MyApp.Domain.Orders.Admin.Usecases.Order.run()
    end
    """)

    assert {out, 0} = lint(dir)
    assert out =~ "нарушений нет"
  end

  test "подсистема → срез контекста через алиас, её `Common` — без нарушения", %{tmp_dir: dir} do
    write(dir, "lib/my_app/mailer/digest.ex", """
    defmodule MyApp.Mailer.Digest do
      alias MyApp.Domain.Orders.{Admin, Common}

      def run, do: {Common.Order.new(), Admin.Usecases.Order.run()}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/mailer/digest.ex:4: "
    assert out =~ "подсистема `MyApp.Mailer`"
    assert out =~ "MyApp.Domain.Orders.Admin.Usecases.Order"
    assert out =~ "нарушений — 1"
  end

  test "сборка приложения и точки входа → любой срез — без нарушений", %{tmp_dir: dir} do
    for {path, module} <- [
          {"lib/my_app/application.ex", "MyApp.Application"},
          {"lib/my_app/codec/internal.ex", "MyApp.Codec.Internal"},
          {"lib/my_app/projections.ex", "MyApp.Projections"},
          {"lib/my_app/prom_ex/workers.ex", "MyApp.PromEx.Workers"},
          {"lib/my_app/release/quick_start.ex", "MyApp.Release.QuickStart"},
          {"lib/mix/tasks/quick_start.ex", "Mix.Tasks.QuickStart"}
        ] do
      write(dir, path, """
      defmodule #{module} do
        def run, do: MyApp.Domain.Orders.Admin.Usecases.Order.run()
      end
      """)
    end

    assert {out, 0} = lint(dir)
    assert out =~ "нарушений нет"
  end

  test "вложенный модуль — под родителем, даже если его имя уже алиас", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/client/order.ex", """
    defmodule MyApp.Domain.Orders.Client.Order do
      alias MyApp.Domain.Orders.Common.Line

      defmodule Line do
        def run, do: MyApp.Domain.Orders.Client.X.run()
      end
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "маркер гасит правило направления и не гасит соседнее", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/common/order.ex", """
    # boundary-lint: allow common-slice — DEBT.md, «Проекция Common зовёт срез»
    defmodule MyApp.Domain.Orders.Common.Order do
      def run, do: {MyApp.Domain.Orders.Admin.X.run(), MyApp.Domain.Billing.Admin.Y.run()}
    end
    """)

    write(dir, "lib/my_app/domain/orders/client/order.ex", """
    # boundary-lint: allow foreign-slice — DEBT.md, «Срез зовёт чужой срез»
    defmodule MyApp.Domain.Orders.Client.Order do
      def run, do: MyApp.Domain.Billing.Admin.Y.run()
    end
    """)

    write(dir, "lib/my_app/mailer/digest.ex", """
    # boundary-lint: allow subsystem-slice — DEBT.md, «Подсистема зовёт срез»
    defmodule MyApp.Mailer.Digest do
      def run, do: MyApp.Domain.Orders.Admin.Y.run()
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/common/order.ex:3: "
    assert out =~ "MyApp.Domain.Billing.Admin.Y"
    assert out =~ "нарушений — 1"
  end

  test "модуль в корне контекста — bc-root на объявлении, ссылки на него срезами не считаются", %{tmp_dir: dir} do
    write_index(dir, "Perms")
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/perms/registry.ex", "defmodule MyApp.Domain.Perms.Registry do\nend\n")
    write(dir, "lib/my_app/domain/perms/common.ex", "defmodule MyApp.Domain.Perms.Common do\nend\n")

    write(dir, "lib/my_app/domain/perms/registry/catalog.ex", """
    defmodule MyApp.Domain.Perms.Registry.Catalog do
    end
    """)

    write(dir, "lib/my_app/domain/orders/common/order.ex", """
    defmodule MyApp.Domain.Orders.Common.Order do
      def run, do: {MyApp.Domain.Perms.Registry.Catalog.all(), MyApp.Domain.Perms.Admin.X.run()}
    end
    """)

    assert {out, 1} = lint(dir)

    assert out =~
             "lib/my_app/domain/perms/registry.ex:1: `MyApp.Domain.Perms.Registry` — модуль в корне контекста `Perms`"

    assert out =~ "MyApp.Domain.Perms.Admin.X"
    assert out =~ "срез инициатора или подсистема `MyApp.<Subsystem>`"
    refute out =~ "Registry.Catalog` — срез"
    assert out =~ "нарушений — 2"
  end

  test "подсистема с другим корнем — subsystem-slice; `<Root>Web` и `Mix.Tasks` — нет", %{tmp_dir: dir} do
    for {path, module} <- [
          {"lib/my_app_extra/digest.ex", "MyAppExtra.Digest"},
          {"lib/other_web/endpoint.ex", "OtherWeb.Endpoint"},
          {"lib/my_app_web/fallback_controller.ex", "MyAppWeb.FallbackController"},
          {"lib/mix/tasks/digest.ex", "Mix.Tasks.Digest"}
        ] do
      write(dir, path, """
      defmodule #{module} do
        def run, do: MyApp.Domain.Orders.Admin.Usecases.Order.run()
      end
      """)
    end

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app_extra/digest.ex:2: подсистема `MyAppExtra`"
    assert out =~ "lib/other_web/endpoint.ex:2: подсистема `OtherWeb`"
    assert out =~ "нарушений — 2"
  end

  test "проекция — только `<ReadModel>.Projection` в каталоге read-модели, проектор запрещён", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    for {path, module} <- [
          {"lib/my_app/domain/orders/common/projection.ex", "MyApp.Domain.Orders.Common.Projection"},
          {"lib/my_app/domain/orders/common/order/projection.ex", "MyApp.Domain.Orders.Common.Order.Projection"},
          {"lib/my_app/domain/orders/admin/backlog/projection_v2.ex", "MyApp.Domain.Orders.Admin.Backlog.ProjectionV2"},
          {"lib/my_app/domain/orders/common/order/writer.ex", "MyApp.Domain.Orders.Common.Order.Writer"}
        ] do
      write(dir, path, "defmodule #{module} do\n  use Core.Es.Projection, name: \"x\"\nend\n")
    end

    write(dir, "lib/my_app/domain/orders/common/order/read_repo/pg/projector.ex", """
    defmodule MyApp.Domain.Orders.Common.Order.ReadRepo.Pg.Projector do
    end
    """)

    assert {out, 1} = lint(dir)

    assert out =~
             "lib/my_app/domain/orders/common/projection.ex:1: `MyApp.Domain.Orders.Common.Projection` — проекция вне"

    assert out =~ "lib/my_app/domain/orders/common/order/writer.ex:1: "
    assert out =~ "Pg.Projector` — отдельный модуль записи"
    assert out =~ "deps/core/docs/rules/app/13-repos.md"
    assert out =~ "нарушений — 3"
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

  test "модуль в корне: ссылки не считаются и под маркером; срез-модуль с usecases — направления и подсказка",
       %{tmp_dir: dir} do
    write_index(dir, "Orders")
    write_index(dir, "Billing")

    write(dir, "lib/my_app/domain/orders/admin.ex", """
    # boundary-lint: allow bc-root — DEBT.md, «Срез модулем»
    defmodule MyApp.Domain.Orders.Admin do
    end
    """)

    write(
      dir,
      "lib/my_app/domain/orders/admin/usecases/order.ex",
      "defmodule MyApp.Domain.Orders.Admin.Usecases.Order do\nend\n"
    )

    write(dir, "lib/my_app/domain/orders/errors.ex", """
    # boundary-lint: allow bc-root — DEBT.md, «Ошибки в корне»
    defmodule MyApp.Domain.Orders.Errors do
      def run, do: MyApp.Domain.Orders.Admin.Usecases.Order.run()
    end
    """)

    write(dir, "lib/my_app/domain/billing/client.ex", "defmodule MyApp.Domain.Billing.Client do\nend\n")

    write(
      dir,
      "lib/my_app/domain/billing/client/usecases/pay.ex",
      "defmodule MyApp.Domain.Billing.Client.Usecases.Pay do\nend\n"
    )

    write(dir, "lib/my_app/domain/orders.ex", """
    defmodule MyApp.Domain.Orders do
      defmodule Registry do
      end
    end
    """)

    write(dir, "lib/my_app/domain/orders/common/order.ex", """
    defmodule MyApp.Domain.Orders.Common.Order do
      def run, do: {MyApp.Domain.Orders.Admin.Usecases.Order.run(), MyApp.Domain.Orders.Errors.x()}
    end
    """)

    assert {out, 1} = lint(dir)

    assert out =~
             "common/order.ex:2: `Common` контекста `Orders` ссылается на `MyApp.Domain.Orders.Admin.Usecases.Order`"

    assert out =~ "lib/my_app/domain/orders.ex:2: `MyApp.Domain.Orders.Registry` — модуль в корне контекста"
    assert out =~ "billing/client.ex:1: `MyApp.Domain.Billing.Client` — срез, объявленный модулем"
    refute out =~ "Orders.Errors`"
    refute out =~ "errors.ex:3"
    assert out =~ "нарушений — 3"
  end

  test "projection-layout: алиас в `use`, вложенный модуль, глубже каталога, `quote`, `Projector` вне ReadRepo",
       %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/common/projection.ex", """
    defmodule MyApp.Domain.Orders.Common.Projection do
      alias Core.Es
      use Es.Projection, name: "orders"
    end
    """)

    write(dir, "lib/my_app/domain/orders/common/order/read_repo/pg.ex", """
    defmodule MyApp.Domain.Orders.Common.Order.ReadRepo.Pg do
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

    write(
      dir,
      "lib/my_app/domain/orders/common/projector.ex",
      "defmodule MyApp.Domain.Orders.Common.Projector do\nend\n"
    )

    assert {out, 1} = lint(dir)
    assert out =~ "common/projection.ex:1: `MyApp.Domain.Orders.Common.Projection` — проекция вне"
    assert out =~ "read_repo/pg.ex:2: `MyApp.Domain.Orders.Common.Order.ReadRepo.Pg.Projection` — проекция вне"
    assert out =~ "read_repo/pg.ex:6: `MyApp.Domain.Orders.Common.Order.ReadRepo.Pg.Projector` — отдельный модуль"
    assert out =~ "нарушений — 3"
  end

  test "сборка приложения — только модули закрытого списка; задача оператора — подсказка `Release`",
       %{tmp_dir: dir} do
    for {path, module} <- [
          {"lib/my_app.ex", "MyApp"},
          {"lib/my_app/application/helper.ex", "MyApp.Application.Helper"},
          {"lib/my_app/projections/any.ex", "MyApp.Projections.Any"},
          {"lib/my_app/codec.ex", "MyApp.Codec"}
        ] do
      write(dir, path, """
      defmodule #{module} do
        def run, do: MyApp.Domain.Orders.Admin.Usecases.Order.run()
      end
      """)
    end

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app.ex:2: подсистема `MyApp` ссылается"
    assert out =~ "application/helper.ex:2: подсистема `MyApp.Application.Helper` (к сборке относится только"
    assert out =~ "lib/my_app/projections/any.ex:2: подсистема `MyApp.Projections.Any`"
    assert out =~ "задача оператора — в `MyApp.Release.<Name>`"
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

  test "DI через `alias … as:`, `defprotocol` по пути, `defimpl` — ссылки модуля `for:`", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/client/usecases/order.ex", """
    defmodule MyApp.Domain.Orders.Client.Usecases.Order do
      alias MyApp.Domain.Orders.Common.Order.Repo, as: OrderRepo
      @repo Application.compile_env(:my_app, OrderRepo)
    end
    """)

    write(dir, "lib/my_app/proto/wrong.ex", "defprotocol MyApp.Renderable do\n  def render(x)\nend\n")

    write(dir, "lib/my_app/domain/orders/common/order/view.ex", """
    defmodule MyApp.Domain.Orders.Common.Order.View do
    end

    defimpl Jason.Encoder, for: MyApp.Domain.Orders.Common.Order.View do
      def encode(view, opts), do: MyApp.Domain.Orders.Admin.Presenter.encode(view, opts)
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "usecases/order.ex:3: `Application.compile_env` на OrderRepo"
    assert out =~ "lib/my_app/proto/wrong.ex:1: модуль `MyApp.Renderable` не по пути"
    assert out =~ "order/view.ex:5: `Common` контекста `Orders` ссылается на `MyApp.Domain.Orders.Admin.Presenter`"
  end

  test "маркер: `DEBT.md` целым словом, keyword-форма модуля; дубли строки сворачиваются", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/wrong.ex", """
    # boundary-lint: allow module-path — see NOT_DEBT.md, «что угодно»
    defmodule MyApp.Other do
    end
    """)

    write(dir, "lib/my_app/domain/orders/common/cart.ex", """
    # boundary-lint: allow common-slice — DEBT.md, «Корзина»
    defmodule MyApp.Domain.Orders.Common.Cart,
      do:
        def(run, do: MyApp.Domain.Orders.Admin.X.a())
    """)

    write(dir, "lib/my_app/domain/orders/common/line.ex", """
    defmodule MyApp.Domain.Orders.Common.Line do
      def run, do: {MyApp.Domain.Orders.Admin.X.a(), MyApp.Domain.Orders.Admin.X.b()}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/wrong.ex:2: модуль `MyApp.Other` не по пути"
    refute out =~ "cart.ex"
    assert out =~ "нарушений — 2"
  end

  test "файл, который не разбирается, — код 2 с путём", %{tmp_dir: dir} do
    write(dir, "lib/my_app/broken.ex", "defmodule MyApp.Broken do\n  def x(, do: 1\nend\n")

    assert {out, 2} = lint(dir)
    assert out =~ "lib/my_app/broken.ex:"
    assert out =~ "не разобран"
  end

  test "срез → соседний срез своего контекста — sibling-slice; свой срез и `Common` — нет", %{tmp_dir: dir} do
    write_index(dir, "Auth")

    write(dir, "lib/my_app/domain/auth/admin/usecases/token.ex", """
    defmodule MyApp.Domain.Auth.Admin.Usecases.Token do
      alias MyApp.Domain.Auth.Client

      def run, do: {Client.Password.hash(), MyApp.Domain.Auth.Admin.Other.x(), MyApp.Domain.Auth.Common.User.new()}
    end
    """)

    assert {out, 1} = lint(dir)

    assert out =~
             "token.ex:4: срез `Admin` контекста `Auth` ссылается на `MyApp.Domain.Auth.Client.Password`"

    assert out =~ "нарушений — 1"
  end

  test "вторая итерация: маркер над `defprotocol`, DI `Repo.Pg` через `as:`, дубли web-root, подсказки ApiSpec",
       %{tmp_dir: dir} do
    write(dir, "lib/my_app.ex", "defmodule MyApp do\nend\n")
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/printable.ex", """
    # boundary-lint: allow bc-root — DEBT.md, «Протокол в корне»
    defprotocol MyApp.Domain.Orders.Printable do
      def print(x)
    end
    """)

    write(dir, "lib/my_app/domain/orders/projection.ex", """
    defmodule MyApp.Domain.Orders.Projection do
      use Core.Es.Projection, name: "orders"
    end
    """)

    write(dir, "lib/my_app/domain/orders/client/usecases/order.ex", """
    defmodule MyApp.Domain.Orders.Client.Usecases.Order do
      alias MyApp.Domain.Orders.Common.Order.Repo, as: OrderRepo
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
    refute out =~ "projection.ex:1: `MyApp.Domain.Orders.Projection` — модуль в корне"
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

    write(dir, "lib/my_app/domain/orders/common/order/event.ex", """
    defmodule MyApp.Domain.Orders.Common.Order.Event do
      defmodule Placed do
        defmodule Payload do
        end
      end
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "event.ex:2: `MyApp.Domain.Orders.Common.Order.Event.Placed` вложен в семейство"
    assert out =~ "lib/my_app/domain/orders/common/order/event/placed.ex"
    refute out =~ "Payload"
    assert out =~ "нарушений — 1"
  end

  test "семейство событий: Prim агрегата `Event`, модуль вне `Domain` и кодек — не члены семейства", %{tmp_dir: dir} do
    write_index(dir, "Calendar")

    write(dir, "lib/my_app/domain/calendar/common/event.ex", """
    defmodule MyApp.Domain.Calendar.Common.Event do
      defmodule ID do
      end
    end
    """)

    write(dir, "lib/my_app/domain/calendar/common/entry/event.ex", """
    defmodule MyApp.Domain.Calendar.Common.Entry.Event do
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
    write(dir, "lib/my_app/domain/orders/common/order.ex", "defmodule MyApp.Domain.Orders.Common.Order do\nend\n")
    write(dir, "lib/my_app/domain/billing/common/invoice.ex", "defmodule MyApp.Domain.Billing.Common.Invoice do\nend\n")
    write_index(dir, "Billing")

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/:0: "
    assert out =~ "lib/my_app/domain/orders.ex"
    assert out =~ "нарушений — 1"
    assert out =~ "правила — #{@layout}"
  end

  test "модуль-оглавление с аббревиатурой в имени контекста — без нарушения", %{tmp_dir: dir} do
    write_index(dir, "CRM")
    write(dir, "lib/my_app/domain/crm/common/lead.ex", "defmodule MyApp.Domain.CRM.Common.Lead do\nend\n")

    assert {_out, 0} = lint(dir)
  end

  test "маркер в модуле контекста гасит отсутствие оглавления, маркер чужого правила — нет", %{tmp_dir: dir} do
    write(dir, "lib/my_app/domain/orders/common/order.ex", """
    # boundary-lint: allow bc-index — DEBT.md, «Контекст без оглавления»
    defmodule MyApp.Domain.Orders.Common.Order do
    end
    """)

    write(dir, "lib/my_app/domain/billing/common/invoice.ex", """
    # boundary-lint: allow module-path — DEBT.md, «Файл не по имени модуля»
    defmodule MyApp.Domain.Billing.Common.Invoice do
    end
    """)

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
    do: write(dir, "lib/my_app/domain/#{Macro.underscore(bc)}.ex", "defmodule MyApp.Domain.#{bc} do\nend\n")

  defp lint(dir, dirs \\ ["lib", "test"]) do
    File.mkdir_p!(Path.join(dir, "test"))
    System.cmd("elixir", [@script, "--consumer" | dirs], cd: dir, env: bare_env(), stderr_to_stdout: true)
  end

  # Скрипту нужны только `elixir` в PATH и UTF-8 локаль: остальное окружение прогона не наследуется.
  defp bare_env do
    for {name, _value} <- System.get_env(), name not in ~w(PATH HOME LANG LC_ALL LC_CTYPE), into: %{}, do: {name, nil}
  end
end
