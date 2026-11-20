defmodule SaasExample.Accounts.User do
  @moduledoc """
  SaaS customer account resource integrating `AshBilling.Resource` and Ash policies.
  """
  use Ash.Resource,
    domain: SaasExample.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "users"
    repo SaasExample.Repo
  end

  billing do
    customer_id_attribute(:stripe_customer_id)
    provider(AshBilling.Providers.Stripe)
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :hashed_password, :string, allow_nil?: false, public?: false, sensitive?: true

    attribute :role, :atom,
      constraints: [one_of: [:member, :admin]],
      default: :member,
      allow_nil?: false,
      public?: true

    timestamps()
  end

  identities do
    identity :unique_email, [:email]
  end

  relationships do
    has_many :subscriptions, SaasExample.Billing.Subscription,
      destination_attribute: :user_id,
      domain: SaasExample.Billing
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:email, :name, :hashed_password, :role]
    end

    update :update do
      primary? true
      accept [:name, :stripe_customer_id, :billing_deleted_at]
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if expr(id == ^actor(:id))
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end
end
