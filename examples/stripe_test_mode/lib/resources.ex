defmodule AshBillingConsumer.Repo do
  use AshPostgres.Repo, otp_app: :ash_billing_consumer, warn_on_missing_ash_functions?: false
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
  def installed_extensions, do: []
end

defmodule AshBillingConsumer.Domain do
  use Ash.Domain, otp_app: :ash_billing_consumer

  resources do
    allow_unregistered? true
    resource AshBillingConsumer.User
    resource AshBillingConsumer.Subscription
    resource AshBillingConsumer.WebhookEvent
  end
end

defmodule AshBillingConsumer.User do
  use Ash.Resource,
    domain: AshBillingConsumer.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "users"
    repo(AshBillingConsumer.Repo)
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
  end

  relationships do
    has_many :subscriptions, AshBillingConsumer.Subscription, destination_attribute: :user_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  policies do
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(id == ^actor(:id))
    end
  end
end

defmodule AshBillingConsumer.Subscription do
  use Ash.Resource,
    domain: AshBillingConsumer.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Subscription]

  postgres do
    table "subscriptions"
    repo(AshBillingConsumer.Repo)
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :user, AshBillingConsumer.User
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing_subscription do
    customer_relationship :user
  end
end

defmodule AshBillingConsumer.WebhookEvent do
  use Ash.Resource,
    domain: AshBillingConsumer.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "webhook_events"
    repo(AshBillingConsumer.Repo)
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end
