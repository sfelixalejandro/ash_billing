defmodule Mix.Tasks.AshBilling.InstallTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  test "installs ash_billing into an existing project with user and router" do
    test_project()
    |> Igniter.create_new_file("lib/test_app/accounts/user.ex", """
    defmodule TestApp.Accounts.User do
      use Ash.Resource,
        domain: TestApp.Accounts

      attributes do
        uuid_primary_key :id
        attribute :email, :string
      end
    end
    """)
    |> Igniter.create_new_file("lib/test_app_web/router.ex", """
    defmodule TestAppWeb.Router do
      use TestAppWeb, :router

      pipeline :api do
        plug :accepts, ["json"]
      end

      scope "/api", TestAppWeb do
        pipe_through :api
      end
    end
    """)
    |> Igniter.create_new_file("config/runtime.exs", """
    import Config
    """)
    |> Igniter.compose_task("ash_billing.install", [
      "--customer-resource",
      "TestApp.Accounts.User",
      "--subscription-resource",
      "TestApp.Billing.Subscription"
    ])
    |> assert_has_patch("lib/test_app/accounts/user.ex", """
    |  use Ash.Resource, domain: TestApp.Accounts, extensions: [AshBilling.Resource]
    """)
    |> assert_has_patch("lib/test_app/accounts/user.ex", """
    |    has_many(:subscriptions, TestApp.Billing.Subscription, destination_attribute: :user_id)
    """)
    |> assert_creates("lib/test_app/billing/subscription.ex")
    |> assert_has_patch("lib/test_app_web/router.ex", """
    |  scope "/webhooks" do
    |    forward("/stripe", AshBilling.Plug,
    |      customer_resource: TestApp.Accounts.User,
    |      subscription_resource: TestApp.Billing.Subscription,
    |      webhook_secret: {Application, :get_env, [:ash_billing, :stripe_webhook_secret]}
    |    )
    |  end
    """)
    |> assert_has_patch("config/runtime.exs", """
    |config :ash_billing,
    |  stripe_api_key: System.get_env("STRIPE_SECRET_KEY"),
    |  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
    """)
  end

  test "automatically detects user resource when not explicitly specified" do
    test_project()
    |> Igniter.create_new_file("lib/test_app/accounts/user.ex", """
    defmodule TestApp.Accounts.User do
      use Ash.Resource,
        domain: TestApp.Accounts

      attributes do
        uuid_primary_key :id
      end
    end
    """)
    |> Igniter.compose_task("ash_billing.install", [])
    |> assert_has_patch("lib/test_app/accounts/user.ex", """
    |  use Ash.Resource, domain: TestApp.Accounts, extensions: [AshBilling.Resource]
    """)
    |> assert_creates("lib/test/billing/subscription.ex")
  end

  test "generates default resources when none exist" do
    test_project()
    |> Igniter.compose_task("ash_billing.install", [])
    |> assert_creates("lib/test/accounts/user.ex")
    |> assert_creates("lib/test/billing/subscription.ex")
  end

  test "generated project includes a registered domain and runtime credentials" do
    igniter = test_project() |> Igniter.compose_task("ash_billing.install", [])
    assert Rewrite.has_source?(igniter.rewrite, "lib/test/billing.ex")
    assert Rewrite.has_source?(igniter.rewrite, "config/runtime.exs")
    domain = content(igniter, "lib/test/billing.ex")
    assert domain =~ "resource(Test.Accounts.User)"
    assert domain =~ "resource(Test.Billing.Subscription)"
    assert content(igniter, "config/config.exs") =~ "ash_domains: [Test.Billing]"
  end

  test "PostgreSQL subscription inherits the customer's repo and registers in its domain" do
    igniter =
      test_project()
      |> Igniter.create_new_file("lib/test/accounts/user.ex", """
      defmodule Test.Accounts.User do
        use Ash.Resource, domain: Test.Accounts, data_layer: AshPostgres.DataLayer
        postgres do
          table "users"
          repo Test.Repo
        end
        attributes do
          uuid_primary_key :id
        end
      end
      """)
      |> Igniter.compose_task("ash_billing.install", [])

    subscription = content(igniter, "lib/test/billing/subscription.ex")
    assert subscription =~ "data_layer: AshPostgres.DataLayer"
    assert subscription =~ "repo(Test.Repo)"
    assert subscription =~ ~s|table("subscriptions")|
    assert content(igniter, "lib/test/accounts.ex") =~ "resource(Test.Billing.Subscription)"
  end

  test "generated router resolves its configured secret and preserves the raw body" do
    igniter =
      test_project()
      |> Igniter.create_new_file("lib/test_web/router.ex", """
      defmodule TestWeb.Router do
        use TestWeb, :router
      end
      """)
      |> Igniter.create_new_file("lib/test_web/endpoint.ex", """
      defmodule TestWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :test
        plug Plug.Parsers, parsers: [:json], json_decoder: Jason
        plug TestWeb.Router
      end
      """)
      |> Igniter.compose_task("ash_billing.install", [])

    assert content(igniter, "lib/test_web/router.ex") =~
             "webhook_secret: {Application, :get_env, [:ash_billing, :stripe_webhook_secret]}"

    assert content(igniter, "lib/test_web/endpoint.ex") =~
             "body_reader: {AshBilling.Plug, :read_body, []}"
  end

  test "generated PostgreSQL resources compile together in an isolated consumer process" do
    igniter =
      test_project()
      |> Igniter.create_new_file("lib/test/accounts/user.ex", """
      defmodule Test.Accounts.User do
        use Ash.Resource, domain: Test.Accounts, data_layer: AshPostgres.DataLayer
        postgres do
          table "users"
          repo Test.Repo
        end
        attributes do
          uuid_primary_key :id
        end
        actions do
          default_accept :*
          defaults [:read, :create, :update]
        end
      end
      """)
      |> Igniter.create_new_file("lib/test/repo.ex", """
      defmodule Test.Repo do
        use AshPostgres.Repo, otp_app: :test, warn_on_missing_ash_functions?: false
        def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
        def installed_extensions, do: []
      end
      """)
      |> Igniter.compose_task("ash_billing.install", [])

    dir =
      Path.join(System.tmp_dir!(), "ash_billing_install_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for path <- Rewrite.paths(igniter.rewrite),
        String.starts_with?(path, "lib/"),
        String.ends_with?(path, ".ex") do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content(igniter, path))
    end

    script = """
    Mix.start()
    defmodule InstallerConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :test, version: "0.1.0"]
    end
    Application.put_env(:ash, :default_string_length_count, :codepoints)
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    {:ok, _} = Application.ensure_all_started(:ash_billing)
    case Kernel.ParallelCompiler.compile(Path.wildcard(#{inspect(dir)} <> "/lib/**/*.ex"), return_diagnostics: true) do
      {:ok, _, warnings} when warnings == [] or warnings == %{compile_warnings: [], runtime_warnings: []} -> :ok
      other -> IO.inspect(other); System.halt(1)
    end
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["-pa", Path.join(File.cwd!(), "_build/test/lib/*/ebin"), "-e", script],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "an existing subscription gets missing customer configuration without replacing custom relationships" do
    base =
      test_project()
      |> Igniter.create_new_file("lib/test/accounts/user.ex", """
      defmodule Test.Accounts.User do
        use Ash.Resource, domain: Test.Billing
        attributes do
          uuid_primary_key :id
        end
      end
      """)

    missing =
      base
      |> Igniter.create_new_file("lib/test/billing/subscription.ex", """
      defmodule Test.Billing.Subscription do
        use Ash.Resource, domain: Test.Billing
        attributes do
          uuid_primary_key :id
        end
      end
      """)
      |> Igniter.compose_task("ash_billing.install", [])

    assert content(missing, "lib/test/billing/subscription.ex") =~ "customer_relationship(:user)"

    assert content(missing, "lib/test/billing/subscription.ex") =~
             "belongs_to(:user, Test.Accounts.User)"

    configured =
      base
      |> Igniter.create_new_file("lib/test/billing/subscription.ex", """
      defmodule Test.Billing.Subscription do
        use Ash.Resource, domain: Test.Billing, extensions: [AshBilling.Subscription]
        attributes do
          uuid_primary_key :id
        end
        relationships do
          belongs_to :account, Test.Accounts.User, source_attribute: :owner_id
        end
        billing_subscription do
          customer_relationship :account
        end
      end
      """)
      |> Igniter.compose_task("ash_billing.install", [])

    source = content(configured, "lib/test/billing/subscription.ex")
    assert source =~ "customer_relationship(:account)"
    refute source =~ "belongs_to(:user,"
    assert content(configured, "lib/test/accounts/user.ex") =~ "destination_attribute: :owner_id"
  end

  test "existing parser body readers are preserved" do
    igniter =
      test_project()
      |> Igniter.create_new_file("lib/test_web/router.ex", """
      defmodule TestWeb.Router do
        use TestWeb, :router
      end
      """)
      |> Igniter.create_new_file("lib/test_web/endpoint.ex", """
      defmodule TestWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :test
        plug Plug.Parsers, parsers: [:json], json_decoder: Jason,
          body_reader: {TestWeb.RawBody, :read_body, []}
        plug TestWeb.Router
      end
      """)
      |> Igniter.compose_task("ash_billing.install", [])

    assert content(igniter, "lib/test_web/endpoint.ex") =~
             "body_reader: {TestWeb.RawBody, :read_body, []}"
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
