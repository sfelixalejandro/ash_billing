# examples/live_subscription_and_portal.exs
#
# Live integration test suite for AshBilling.
# Executes end-to-end live integration verifications against the official Stripe API
# and the Igniter AST code transformation engine.
#
# Execution:
#   STRIPE_SECRET_KEY=sk_test_... mix run examples/live_subscription_and_portal.exs

Code.require_file("test/support/resources.ex")

defmodule AshBilling.LiveSubscriptionSuite do
  @stripe_key System.get_env("STRIPE_SECRET_KEY")

  def run do
    print_banner("STARTING ASH_BILLING LIVE SUBSCRIPTION SUITE")

    if is_nil(@stripe_key) or not String.starts_with?(@stripe_key, "sk_") do
      IO.puts("[ERROR] STRIPE_SECRET_KEY environment variable required (sk_test_...)")
      System.halt(1)
    end

    test_test_a_recurring_subscription()
    test_test_b_real_webhook_event_sync()
    test_test_c_customer_billing_portal()
    test_test_d_igniter_code_generation()

    print_summary()
  end

  # ============================================================================
  # TEST A: Checkout Session for Monthly Recurring Subscription
  # ============================================================================
  defp test_test_a_recurring_subscription do
    step("Test A: Checkout Session Creation for Recurring Subscription (mode: subscription)")

    IO.puts("    [INFO] Invoking AshBilling.create_checkout_session with recurring price...")

    case AshBilling.create_checkout_session(
           "cus_VW0w1VWfmjjQFr",
           mode: "subscription",
           line_items: [
             %{
               price_data: %{
                 currency: "usd",
                 unit_amount: 1900,
                 recurring: %{interval: "month"},
                 product_data: %{name: "AshBilling Pro Monthly Plan"}
               },
               quantity: 1
             }
           ],
           success_url: "https://example.com/billing/success",
           cancel_url: "https://example.com/billing/cancel",
           api_key: @stripe_key
         ) do
      {:ok, session} ->
        assert_not_nil("Generated Session ID", session.id)
        assert_not_nil("Stripe Checkout URL", session.url)
        assert_starts_with("Session prefix cs_test_", session.id, "cs_test_")
        assert_starts_with("Official Stripe URL", session.url, "https://checkout.stripe.com")

        IO.puts("    [OK] Session ID: #{session.id}")
        IO.puts("    [OK] Recurring Checkout URL: #{session.url}")
        pass("Recurring subscription created successfully on official Stripe servers")

      {:error, reason} ->
        fail("Failed to create recurring Checkout Session: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # TEST B: Webhook Synchronization with Live Stripe Event Payload
  # ============================================================================
  defp test_test_b_real_webhook_event_sync do
    step("Test B: Webhook Synchronization with Live Payload downloaded from Stripe API")

    IO.puts("    [INFO] Fetching real event evt_1UUz0HRtBbl3OzwdYnR8HPu1 from Stripe API...")

    resp =
      Req.get!("https://api.stripe.com/v1/events/evt_1UUz0HRtBbl3OzwdYnR8HPu1",
        auth: {:bearer, @stripe_key}
      )

    assert_eq("Stripe API HTTP 200 response", resp.status, 200)
    event_data = resp.body
    assert_eq("Exact event type", event_data["type"], "checkout.session.completed")

    user_uuid = event_data["data"]["object"]["client_reference_id"]
    customer_id = event_data["data"]["object"]["customer"]

    IO.puts("    [INFO] client_reference_id extracted from Stripe: #{user_uuid}")
    IO.puts("    [INFO] Stripe customer ID: #{customer_id}")

    # Seed the user in Ash test database
    {:ok, _user} =
      AshBilling.Test.User
      |> Ash.Changeset.for_create(:create, %{
        email: "sfelixalejandro@enterprise.com",
        name: "Alejandro Felix"
      })
      |> Ash.Changeset.force_change_attribute(:id, user_uuid)
      |> Ash.create(domain: AshBilling.Test.Domain)

    # Process the synchronization
    {:ok, updated_user} =
      AshBilling.WebhookSync.sync_event(
        event_data,
        domain: AshBilling.Test.Domain,
        customer_resource: AshBilling.Test.User,
        subscription_resource: AshBilling.Test.Subscription
      )

    assert_eq("Synchronized User UUID", updated_user.id, user_uuid)
    assert_eq("Persisted Stripe Customer ID", updated_user.stripe_customer_id, customer_id)

    pass("Real Stripe event parsed, validated, and persisted into Ash resource with zero errors")
  end

  # ============================================================================
  # TEST C: Stripe Customer Billing Portal Session
  # ============================================================================
  defp test_test_c_customer_billing_portal do
    step("Test C: Live Customer Portal Session Creation (billing.stripe.com)")

    IO.puts("    [INFO] Invoking AshBilling.create_portal_session for cus_VW0w1VWfmjjQFr...")

    case AshBilling.create_portal_session(
           "cus_VW0w1VWfmjjQFr",
           return_url: "https://example.com/account/billing",
           api_key: @stripe_key
         ) do
      {:ok, portal} ->
        assert_not_nil("Generated Portal URL", portal.url)

        assert_starts_with(
          "Official Stripe Billing URL",
          portal.url,
          "https://billing.stripe.com"
        )

        IO.puts("    [OK] Customer Portal URL: #{portal.url}")
        pass("Self-service Customer Portal session created successfully on Stripe")

      {:error, reason} ->
        fail("Failed to create customer portal session: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # TEST D: Automated Code Generation and AST Transformation via Igniter
  # ============================================================================
  defp test_test_d_igniter_code_generation do
    step("Test D: Igniter Automated Installation Engine Verification")

    IO.puts("    [INFO] Executing Mix.Tasks.AshBilling.Install on virtual project with AST...")

    igniter =
      Igniter.Test.test_project()
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

    # Verify User resource received AshBilling.Resource extension
    user_content =
      igniter.rewrite
      |> Rewrite.source!("lib/test_app/accounts/user.ex")
      |> Rewrite.Source.get(:content)

    assert_contains("Extension added to User", user_content, "extensions: [AshBilling.Resource]")

    assert_contains(
      "subscriptions relationship added",
      user_content,
      "has_many(:subscriptions, TestApp.Billing.Subscription)"
    )

    # Verify Subscription resource creation
    assert_true(
      "Subscription.ex file created",
      Rewrite.has_source?(igniter.rewrite, "lib/test_app/billing/subscription.ex")
    )

    # Verify Webhook Plug mounted in Router
    router_content =
      igniter.rewrite
      |> Rewrite.source!("lib/test_app_web/router.ex")
      |> Rewrite.Source.get(:content)

    assert_contains(
      "Scope /webhooks mounted",
      router_content,
      "forward(\"/stripe\", AshBilling.Plug"
    )

    # Verify runtime.exs configuration
    runtime_content =
      igniter.rewrite
      |> Rewrite.source!("config/runtime.exs")
      |> Rewrite.Source.get(:content)

    assert_contains("runtime.exs configuration injected", runtime_content, "stripe_api_key:")

    pass(
      "Igniter successfully modified code, created resources, and configured router with clean syntax"
    )
  end

  # ============================================================================
  # Assertion Helpers
  # ============================================================================
  defp step(title) do
    IO.puts("")
    IO.puts("==> #{title}")
  end

  defp pass(msg) do
    IO.puts("    [VERIFIED] #{msg}")
  end

  defp fail(msg) do
    IO.puts("    [CRITICAL FAILURE] #{msg}")
    raise msg
  end

  defp assert_eq(label, actual, expected) do
    if actual == expected do
      IO.puts("    [OK] #{label}: #{inspect(actual)}")
    else
      fail("#{label} - Expected: #{inspect(expected)}, Got: #{inspect(actual)}")
    end
  end

  defp assert_not_nil(label, actual) do
    if not is_nil(actual) do
      IO.puts("    [OK] #{label}: present")
    else
      fail("#{label} - Expected non-nil value, got nil")
    end
  end

  defp assert_starts_with(label, actual, prefix) do
    if is_binary(actual) and String.starts_with?(actual, prefix) do
      IO.puts("    [OK] #{label}: prefix matches (#{prefix})")
    else
      fail("#{label} - Expected prefix #{prefix}, got: #{inspect(actual)}")
    end
  end

  defp assert_contains(label, content, pattern) do
    if is_binary(content) and String.contains?(content, pattern) do
      IO.puts("    [OK] #{label}: pattern found")
    else
      fail("#{label} - Pattern #{pattern} not found in content")
    end
  end

  defp assert_true(label, condition) do
    if condition == true do
      IO.puts("    [OK] #{label}: true")
    else
      fail("#{label} - Condition not met")
    end
  end

  defp print_banner(title) do
    IO.puts("================================================================================")
    IO.puts("  #{title}")
    IO.puts("================================================================================")
  end

  defp print_summary do
    IO.puts("")
    IO.puts("================================================================================")
    IO.puts("  ALL LIVE SUBSCRIPTION TESTS (A, B, C, D) PASSED SUCCESSFULLY (100%)")
    IO.puts("================================================================================")
  end
end

AshBilling.LiveSubscriptionSuite.run()
