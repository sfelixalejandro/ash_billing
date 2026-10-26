defmodule Mix.Tasks.AshBilling.InstallTest do
  use ExUnit.Case, async: true

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
    |    has_many(:subscriptions, TestApp.Billing.Subscription)
    """)
    |> assert_creates("lib/test_app/billing/subscription.ex")
    |> assert_has_patch("lib/test_app_web/router.ex", """
    |  scope "/webhooks" do
    |    forward("/stripe", AshBilling.Plug,
    |      resource: TestApp.Accounts.User,
    |      subscription_resource: TestApp.Billing.Subscription
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
end
