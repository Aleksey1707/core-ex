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
      alias MyApp.Domain.Orders.{Client, Common}

      def run, do: {Common.Order.new(), Client.Usecases.Order.run(), __MODULE__}
    end
    """)

    write(dir, "lib/my_app_web/orders_controller.ex", """
    defmodule MyAppWeb.OrdersController do
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

  test "вложенный модуль — под родителем, даже если его имя уже алиас", %{tmp_dir: dir} do
    write_index(dir, "Orders")

    write(dir, "lib/my_app/domain/orders/client/order.ex", """
    defmodule MyApp.Domain.Orders.Client.Order do
      alias MyApp.Domain.Orders.Common.Line

      defmodule Line do
        def run, do: MyApp.Domain.Orders.Admin.X.run()
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

    assert {out, 1} = lint(dir)
    assert out =~ "lib/my_app/domain/orders/common/order.ex:3: "
    assert out =~ "MyApp.Domain.Billing.Admin.Y"
    assert out =~ "нарушений — 1"
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
