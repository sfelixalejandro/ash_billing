defmodule SaasExampleWeb.Plugs.StripeWebhookPlug do
  @moduledoc """
  Runtime-configured wrapper around `AshBilling.Plug` for `/webhooks/stripe`.

  Enforces HMAC signature verification, `expected_livemode`, PostgreSQL `:resource`
  deduplication (`SaasExample.Billing.WebhookEvent`), bounded HTTP timeouts for
  post-reconciliation re-verification, and fail-closed HTTP 500 responses on sync errors.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    runtime_opts =
      [
        provider: Application.get_env(:ash_billing, :provider, AshBilling.Providers.Stripe),
        api_key: Application.get_env(:ash_billing, :api_key),
        webhook_secret: Application.get_env(:ash_billing, :webhook_secret),
        expected_livemode: Application.get_env(:ash_billing, :expected_livemode, false),
        req_opts: Application.get_env(:ash_billing, :req_opts, []),
        customer_resource: SaasExample.Accounts.User,
        subscription_resource: SaasExample.Billing.Subscription,
        domain: SaasExample.Billing,
        deduplicate?: true,
        deduplication_strategy: :resource,
        deduplication_resource: SaasExample.Billing.WebhookEvent,
        return_500_on_sync_error: true
      ]
      |> Keyword.merge(Application.get_env(:saas_example, :webhook_plug_opts, []))
      |> Keyword.merge(opts)

    AshBilling.Plug.call(conn, AshBilling.Plug.init(runtime_opts))
  end
end
