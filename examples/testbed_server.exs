# AshBilling Local Stripe Testbed Server
# Run with: mix run examples/testbed_server.exs

defmodule AshBilling.Testbed.Router do
  use Plug.Router
  import Plug.Conn
  require Logger

  plug :match
  plug :dispatch

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", app: "ash_billing_testbed"}))
  end

  get "/state" do
    users = Ash.read!(AshBilling.Test.User, domain: AshBilling.Test.Domain)
    loaded_users = Enum.map(users, fn u ->
      u = Ash.load!(u, :subscriptions, domain: AshBilling.Test.Domain)
      %{
        id: u.id,
        email: u.email,
        stripe_customer_id: u.stripe_customer_id,
        subscriptions: Enum.map(u.subscriptions, fn s ->
          %{
            id: s.id,
            provider_subscription_id: s.provider_subscription_id,
            status: s.status,
            price_id: s.price_id,
            active: AshBilling.subscribed?(u),
            trial_ends_at: s.trial_ends_at
          }
        end)
      }
    end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{users: loaded_users}))
  end

  def webhook_secret do
    System.get_env("STRIPE_WEBHOOK_SECRET") || "whsec_test_cli_secret"
  end

  forward "/webhooks/stripe",
    to: AshBilling.Plug,
    init_opts: [
      provider: AshBilling.Providers.Stripe,
      webhook_secret: {AshBilling.Testbed.Router, :webhook_secret, []},
      customer_resource: AshBilling.Test.User,
      subscription_resource: AshBilling.Test.Subscription,
      domain: AshBilling.Test.Domain
    ]

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end

defmodule AshBilling.Testbed do
  require Logger

  def start do
    port = String.to_integer(System.get_env("PORT") || "4000")
    secret = System.get_env("STRIPE_WEBHOOK_SECRET") || "whsec_test_cli_secret"

    # Pre-seed a test user to test subscription events
    {:ok, user} =
      Ash.create(
        AshBilling.Test.User,
        %{email: "alex@enterprise-saas.com", name: "Alex Felix", stripe_customer_id: "cus_test_alex_999"},
        domain: AshBilling.Test.Domain
      )

    IO.puts("")
    IO.puts("================================================================================")
    IO.puts("               ASH_BILLING - LOCAL STRIPE TESTBED SERVER                        ")
    IO.puts("================================================================================")
    IO.puts("  Listening on:          http://localhost:#{port}")
    IO.puts("  Webhook endpoint:      http://localhost:#{port}/webhooks/stripe")
    IO.puts("  Live state inspector:  http://localhost:#{port}/state")
    IO.puts("  Webhook Secret:        #{secret}")
    IO.puts("  Pre-seeded Test User:  ID=#{user.id}, CustomerID=#{user.stripe_customer_id}")
    IO.puts("================================================================================")
    IO.puts("  Ready to receive webhooks from Stripe CLI or network requests.")
    IO.puts("  Press Ctrl+C to stop.")
    IO.puts("")

    {:ok, _} = Bandit.start_link(plug: AshBilling.Testbed.Router, port: port)
    Process.sleep(:infinity)
  end
end

# Ensure test support modules are loaded
Code.require_file("test/support/resources.ex")

AshBilling.Testbed.start()
