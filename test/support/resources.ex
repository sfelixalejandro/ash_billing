defmodule AshBilling.Test.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBilling.Test.User
    resource AshBilling.Test.CustomUser
    resource AshBilling.Test.Subscription
    resource AshBilling.Test.PolicyUser
    resource AshBilling.Test.PolicySubscription
    resource AshBilling.Test.WebhookEvent
    resource AshBilling.Test.SimpleEvent
    resource AshBilling.Test.ReadOnlyEvent
    resource AshBilling.Test.FailingUpdateEvent
    resource AshBilling.Test.PremiumFeature
    resource AshBilling.Test.IncompleteResource
    resource AshBilling.Test.NoUpdateEvent
    resource AshBilling.Test.NoUpdateNoDestroyEvent
    resource AshBilling.Test.EventWithoutToken
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
    default_accept [:*, :stripe_customer_id]
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
    default_accept [:*, :custom_stripe_id]
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
    default_accept [:*, :stripe_customer_id]
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

defmodule AshBilling.Test.SimpleEvent do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :event_id, :string, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create, :destroy]
  end
end

defmodule AshBilling.Test.ReadOnlyEvent do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :event_id, :string, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create]
  end
end

defmodule AshBilling.Test.FailingUpdateEvent do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.WebhookEvent]

  actions do
    default_accept :*
    defaults [:read, :create, :destroy]

    update :update do
      primary? true
      require_atomic? false

      validate fn _changeset, _context ->
        {:error, field: :status, message: "simulated_persistence_failure"}
      end
    end
  end
end

defmodule AshBilling.Test.PremiumFeature do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]

    read :pro_only do
      # specialized read action
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if AshBilling.Checks.Subscribed
    end

    policy action(:pro_only) do
      authorize_if {AshBilling.Checks.HasPrice, price: "price_pro"}
    end
  end
end

defmodule AshBilling.Test.IncompleteResource do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.NoUpdateEvent do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :event_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :status, :atom, default: :processing, public?: true
    attribute :lease_token, :string, public?: true
    attribute :last_attempt_at, :utc_datetime_usec, public?: true
    attribute :processed_at, :utc_datetime_usec, public?: true
    attribute :attempts, :integer, default: 1, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create, :destroy]
  end
end

defmodule AshBilling.Test.NoUpdateNoDestroyEvent do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :event_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :status, :atom, default: :processing, public?: true
    attribute :lease_token, :string, public?: true
    attribute :last_attempt_at, :utc_datetime_usec, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create]
  end
end

defmodule AshBilling.Test.EventWithoutToken do
  use Ash.Resource,
    domain: AshBilling.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :event_id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:processing, :processed, :failed]],
      default: :processing,
      public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end
