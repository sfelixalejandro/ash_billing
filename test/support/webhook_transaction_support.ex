defmodule AshBilling.Test.TransactionRepo do
  use AshPostgres.Repo, otp_app: :ash_billing, warn_on_missing_ash_functions?: false
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
  def installed_extensions, do: ["uuid-ossp", "citext"]
end

defmodule AshBilling.Test.TransactionDomain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBilling.Test.TransactionWebhookEvent
    resource AshBilling.Test.CrossRepoSubscription
    resource AshBilling.Test.PostgresCustomer
    resource AshBilling.Test.PostgresWebhookEvent
  end
end

defmodule AshBilling.Test.TransactionWebhookEvent do
  use Ash.Resource,
    domain: AshBilling.Test.TransactionDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "webhook_events"
    repo(AshBilling.Test.TransactionRepo)
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.CrossRepoSubscription do
  use Ash.Resource,
    domain: AshBilling.Test.TransactionDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Subscription]

  postgres do
    table "billing_test_subscriptions"
    repo(AshBilling.Test.TransactionRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, public?: true
  end

  relationships do
    belongs_to :user, AshBilling.Test.PostgresCustomer
  end

  billing_subscription do
    customer_relationship :user
  end

  actions do
    default_accept [
      :*,
      :provider_subscription_id,
      :status,
      :price_id,
      :current_period_end,
      :cancel_at_period_end,
      :cancel_at,
      :trial_ends_at,
      :last_event_created_at,
      :user_id
    ]

    defaults [:read, :create, :update, :destroy]
  end
end
