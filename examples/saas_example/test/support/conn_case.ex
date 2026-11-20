defmodule SaasExampleWeb.ConnCase do
  @moduledoc """
  Shared test helpers for Phoenix HTTP requests, real HMAC-signed Stripe webhooks,
  `Req.Test` Stripe HTTP stubbing, and clean PostgreSQL state between tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SaasExampleWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import SaasExampleWeb.ConnCase
    end
  end

  setup do
    Ecto.Adapters.SQL.query!(
      SaasExample.Repo,
      "TRUNCATE workspace_reports, workspace_seats, subscriptions, webhook_events, users CASCADE"
    )

    prev_req_opts = Application.get_env(:ash_billing, :req_opts)
    prev_webhook_opts = Application.get_env(:saas_example, :webhook_plug_opts)

    on_exit(fn ->
      Application.put_env(:ash_billing, :req_opts, prev_req_opts)

      if is_nil(prev_webhook_opts) do
        Application.delete_env(:saas_example, :webhook_plug_opts)
      else
        Application.put_env(:saas_example, :webhook_plug_opts, prev_webhook_opts)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def create_user!(attrs \\ %{}) do
    defaults = %{
      email: "user_#{System.unique_integer([:positive])}@example.com",
      name: "Test User",
      password: "password1234",
      role: :member
    }

    {:ok, user} = SaasExample.Accounts.register_user(Map.merge(defaults, attrs))

    user =
      case Map.get(attrs, :stripe_customer_id) do
        nil ->
          user

        cust_id ->
          user
          |> Ash.Changeset.for_update(:update, %{stripe_customer_id: cust_id})
          |> Ash.update!(domain: SaasExample.Accounts, authorize?: false)
      end

    {:ok, loaded} = SaasExample.Accounts.load_fresh_actor(user.id)
    loaded
  end

  def create_subscription!(user, attrs \\ %{}) do
    defaults = %{
      user_id: user.id,
      provider_subscription_id: "sub_test_#{System.unique_integer([:positive])}",
      status: :active,
      price_id: SaasExample.Billing.Catalog.price_id!(:starter),
      quantity: 2,
      provider_subscription_item_id: "si_test_#{System.unique_integer([:positive])}",
      current_period_end: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
    }

    SaasExample.Billing.Subscription
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.Changeset.force_change_attributes(Map.merge(defaults, attrs))
    |> Ash.create!(domain: SaasExample.Billing, authorize?: false)
  end

  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{user_id: user.id})
  end

  def configure_stripe_stub(plug_name, fun) do
    Req.Test.stub(plug_name, fun)

    req_opts = [
      plug: {Req.Test, plug_name},
      connect_options: [timeout: 3_000],
      receive_timeout: 5_000,
      retry: false
    ]

    Application.put_env(:ash_billing, :req_opts, req_opts)
    :ok
  end

  def sign_stripe_payload(raw_body, secret \\ nil, timestamp \\ nil) do
    secret = secret || Application.fetch_env!(:ash_billing, :webhook_secret)
    ts = timestamp || System.system_time(:second)
    signed = "#{ts}.#{raw_body}"

    sig =
      :crypto.mac(:hmac, :sha256, secret, signed)
      |> Base.encode16(case: :lower)

    "t=#{ts},v1=#{sig}"
  end

  def post_signed_webhook(conn, event_map, opts \\ []) do
    raw_body = Jason.encode!(event_map)
    secret = Keyword.get(opts, :secret)
    sig_header = Keyword.get(opts, :signature) || sign_stripe_payload(raw_body, secret)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("stripe-signature", sig_header)
    |> Phoenix.ConnTest.dispatch(SaasExampleWeb.Endpoint, :post, "/webhooks/stripe", raw_body)
  end

  def stripe_subscription_payload(sub_id, customer_id, price_id, quantity, opts \\ []) do
    item_id = Keyword.get(opts, :item_id, "si_#{sub_id}")
    status = Keyword.get(opts, :status, "active")
    cancel_at_period_end = Keyword.get(opts, :cancel_at_period_end, false)
    period_end = Keyword.get(opts, :current_period_end, System.system_time(:second) + 2_592_000)

    item =
      %{
        "id" => item_id,
        "price" => %{"id" => price_id}
      }
      |> then(fn map ->
        if Keyword.get(opts, :omit_quantity?, false),
          do: map,
          else: Map.put(map, "quantity", quantity)
      end)

    %{
      "id" => sub_id,
      "object" => "subscription",
      "customer" => customer_id,
      "status" => status,
      "cancel_at_period_end" => cancel_at_period_end,
      "current_period_end" => period_end,
      "items" => %{
        "object" => "list",
        "data" => [item]
      }
    }
  end
end
