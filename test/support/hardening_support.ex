defmodule AshBilling.Test.HardeningProvider do
  @behaviour AshBilling.Provider
  for {name, arity} <- AshBilling.Provider.behaviour_info(:callbacks) do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: result(unquote(name), [unquote_splicing(args)])
  end

  def complete_event(event_id, token, opts) do
    AshBilling.Deduplication.with_lease(event_id, token, opts, fn ->
      AshBilling.Deduplication.complete(event_id, [lease_token: token] ++ opts)
    end)
  end

  defp result(name, args) do
    send(self(), {:provider_called, name, args})

    case name do
      :create_customer ->
        {:ok, "cus_custom"}

      :create_checkout_session ->
        {:ok, %{url: "https://checkout.test", id: "session_custom"}}

      :create_portal_session ->
        {:ok, %{url: "https://portal.test"}}

      :get_subscription ->
        {:ok,
         %{
           "status" => "active",
           "items" => %{"data" => [%{"id" => "si_custom", "price" => %{"id" => "price_custom"}}]}
         }}

      _ ->
        {:ok, %{}}
    end
  end
end

defmodule AshBilling.Test.HardeningDomain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBilling.Test.ConsumerUser
    resource AshBilling.Test.ConsumerSubscription
    resource AshBilling.Test.TenantEvent
    resource AshBilling.Test.CustomProviderSubscription
    resource AshBilling.Test.TenantEventWithoutUpdate
    resource AshBilling.Test.PostgresScopedCustomer
    resource AshBilling.Test.PostgresOwnedScopedSubscription
    resource AshBilling.Test.ConsumerAlternateUser
  end
end

defmodule AshBilling.Test.ConsumerUser do
  use Ash.Resource,
    domain: AshBilling.Test.HardeningDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.Resource],
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :subscriptions, AshBilling.Test.ConsumerSubscription, destination_attribute: :user_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  billing do
    provider AshBilling.Test.HardeningProvider
  end
end

defmodule AshBilling.Test.ConsumerSubscription do
  use Ash.Resource,
    domain: AshBilling.Test.HardeningDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.Subscription],
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, public?: true
  end

  relationships do
    belongs_to :user, AshBilling.Test.ConsumerUser
  end

  billing_subscription do
    customer_relationship :user
  end

  actions do
    default_accept :*
    defaults [:read, :destroy]

    create :create do
      primary? true
      validate one_of(:status, [:active, :canceled])
    end

    update :update do
      primary? true
      accept :*
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end
end

defmodule AshBilling.Test.TenantEvent do
  use Ash.Resource,
    domain: AshBilling.Test.HardeningDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "billing_tenant_events"
    repo(AshBilling.Test.Repo)
  end

  attributes do
    attribute :tenant_id, :string, primary_key?: true, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.CustomProviderSubscription do
  use Ash.Resource,
    domain: AshBilling.Test.HardeningDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.Subscription]

  attributes do
    uuid_primary_key :id
  end

  billing_subscription do
    provider AshBilling.Test.HardeningProvider
  end

  actions do
    default_accept [:provider_subscription_id, :status, :price_id, :last_event_created_at]
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.TenantEventWithoutUpdate do
  use Ash.Resource,
    domain: AshBilling.Test.HardeningDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "billing_tenant_events"
    repo(AshBilling.Test.Repo)
  end

  attributes do
    attribute :tenant_id, :string, primary_key?: true, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :destroy]
  end
end

defmodule AshBilling.Test.ConsumerAlternateUser do
  use Ash.Resource,
    domain: AshBilling.Test.HardeningDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.Resource]

  attributes do
    uuid_primary_key :id
    attribute :payment_customer_id, :string, public?: true
    attribute :billing_deleted_at, :utc_datetime_usec, public?: true
  end

  billing do
    customer_id_attribute :payment_customer_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]

    update :trusted_repair do
      accept [:payment_customer_id]
    end
  end
end

defmodule AshBilling.Test.OverrideProvider do
  @behaviour AshBilling.Provider
  for {name, arity} <- AshBilling.Provider.behaviour_info(:callbacks) do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: {:error, :explicit_override}
  end
end

defmodule AshBilling.Test.TenantRef do
  defstruct [:value]
end

defimpl Ash.ToTenant, for: AshBilling.Test.TenantRef do
  def to_tenant(%{value: tenant}, _resource), do: tenant
end
