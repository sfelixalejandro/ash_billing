defmodule AshBilling.Test.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBilling.Test.User
    resource AshBilling.Test.CustomUser
    resource AshBilling.Test.Subscription
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

  billing_subscription do
    customer_relationship(:user)
  end
end
