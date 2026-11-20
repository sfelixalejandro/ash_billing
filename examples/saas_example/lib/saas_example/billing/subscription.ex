defmodule SaasExample.Billing.Subscription do
  @moduledoc """
  PostgreSQL-backed Ash subscription resource using `AshBilling.Subscription`
  (0.6.0 `last_reconciled_at` + 0.7.0 `quantity` and `provider_subscription_item_id`)
  with strict owner read policies and admin/system-only mutation controls.
  """
  use Ash.Resource,
    domain: SaasExample.Billing,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Subscription],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "subscriptions"
    repo SaasExample.Repo
  end

  billing_subscription do
    customer_relationship(:user)
    provider(AshBilling.Providers.Stripe)
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :user, SaasExample.Accounts.User, domain: SaasExample.Accounts
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end
end
