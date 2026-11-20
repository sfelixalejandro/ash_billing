import Config

config :ash,
  default_string_length_count: :codepoints

config :saas_example,
  env: config_env(),
  ecto_repos: [SaasExample.Repo],
  ash_domains: [
    SaasExample.Accounts,
    SaasExample.Billing,
    SaasExample.Workspace
  ],
  plan_prices: %{
    starter: System.get_env("STRIPE_PRICE_STARTER") || "price_starter_monthly",
    pro: System.get_env("STRIPE_PRICE_PRO") || "price_pro_monthly",
    enterprise: System.get_env("STRIPE_PRICE_ENTERPRISE") || "price_enterprise_monthly"
  }

config :saas_example, SaasExampleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SaasExampleWeb.ErrorHTML, json: SaasExampleWeb.ErrorJSON],
    layout: false
  ]

config :ash_billing,
  provider: AshBilling.Providers.Stripe,
  domain: SaasExample.Billing,
  customer_resource: SaasExample.Accounts.User,
  subscription_resource: SaasExample.Billing.Subscription,
  deduplication_strategy: :resource,
  deduplication_resource: SaasExample.Billing.WebhookEvent,
  expected_livemode: false,
  req_opts: [
    connect_options: [timeout: 3_000],
    receive_timeout: 5_000,
    retry: false
  ]

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
