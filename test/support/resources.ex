defmodule AshBilling.Test.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBilling.Test.User
    resource AshBilling.Test.CustomUser
    resource AshBilling.Test.Subscription
    resource AshBilling.Test.PolicyUser
    resource AshBilling.Test.PolicySubscription
    resource AshBilling.Test.WebhookEvent
  end
end

defmodule AshBilling.Test.User do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.Resource]

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :subscriptions, AshBilling.Test.Subscription, destination_attribute: :user_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing do
    # Defaults: customer_id_attribute :stripe_customer_id
  end
end

defmodule AshBilling.Test.CustomUser do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.Resource]

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing do
    customer_id_attribute(:custom_stripe_id)
  end
end

defmodule AshBilling.Test.Subscription do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.Subscription]

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, public?: true
  end

  relationships do
    belongs_to :user, AshBilling.Test.User
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing_subscription do
    customer_relationship(:user)
  end
end

defmodule AshBilling.Test.PolicyUser do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshBilling.Resource]

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
  end

  relationships do
    has_many :subscriptions, AshBilling.Test.PolicySubscription, destination_attribute: :user_id
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.PolicySubscription do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshBilling.Subscription]

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, public?: true
  end

  relationships do
    belongs_to :user, AshBilling.Test.PolicyUser
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing_subscription do
    customer_relationship(:user)
  end
end

defmodule AshBilling.Test.WebhookEvent do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.WebhookEvent]

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end
