defmodule AshBilling.Test.Repo do
  use AshPostgres.Repo,
    otp_app: :ash_billing,
    warn_on_missing_ash_functions?: false

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  def installed_extensions do
    ["uuid-ossp", "citext"]
  end
end

defmodule AshBilling.Test.PostgresWebhookEvent do
  use Ash.Resource,
    domain: AshBilling.Test.PostgresDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "webhook_events"
    repo(AshBilling.Test.Repo)
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.PostgresCustomer do
  use Ash.Resource,
    domain: AshBilling.Test.PostgresDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Resource]

  postgres do
    table "billing_test_customers"
    repo(AshBilling.Test.Repo)
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
  end

  relationships do
    has_many :subscriptions, AshBilling.Test.PostgresSubscription, destination_attribute: :user_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.PostgresSubscription do
  use Ash.Resource,
    domain: AshBilling.Test.PostgresDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Subscription]

  postgres do
    table "billing_test_subscriptions"
    repo(AshBilling.Test.Repo)
  end

  attributes do
    uuid_primary_key :id
  end

  attributes do
    attribute :user_id, :uuid, public?: true
  end

  relationships do
    belongs_to :user, AshBilling.Test.PostgresCustomer
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing_subscription do
    customer_relationship :user
  end
end

defmodule AshBilling.Test.PostgresDomain do
  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshBilling.Test.PostgresCustomer
    resource AshBilling.Test.PostgresSubscription
    resource AshBilling.Test.PostgresWebhookEvent
  end
end
