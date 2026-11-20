defmodule SaasExample.Workspace.Report do
  @moduledoc """
  Workspace report resource demonstrating Ash authorization policies using both
  `AshBilling.Checks.Subscribed` and `AshBilling.Checks.HasPrice` combined with
  strict owner isolation.

  - `:read` / `:create_for_owner` -> Requires any active subscription (`Subscribed`) + ownership.
  - `:export_analytics` -> Requires Pro or Enterprise plan (`HasPrice` list) + ownership.
  - `:enterprise_audit` -> Requires Enterprise plan (`HasPrice` single price) + ownership.
  """
  use Ash.Resource,
    domain: SaasExample.Workspace,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @plan_prices Application.compile_env(:saas_example, :plan_prices, %{})
  @pro_price Map.get(@plan_prices, :pro, "price_pro_monthly")
  @enterprise_price Map.get(@plan_prices, :enterprise, "price_enterprise_monthly")

  postgres do
    table "workspace_reports"
    repo SaasExample.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :owner_id, :uuid, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :summary, :string, allow_nil?: true, public?: true
    attribute :exported_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :audited_at, :utc_datetime_usec, allow_nil?: true, public?: true
    timestamps()
  end

  relationships do
    belongs_to :owner, SaasExample.Accounts.User,
      source_attribute: :owner_id,
      domain: SaasExample.Accounts
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:owner_id, :title, :summary]
    end

    create :create_for_owner do
      accept [:title, :summary]
      change relate_actor(:owner)
    end

    update :export_analytics do
      accept []
      require_atomic? false
      change set_attribute(:exported_at, &DateTime.utc_now/0)
    end

    update :enterprise_audit do
      accept []
      require_atomic? false
      change set_attribute(:audited_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:create_for_owner) do
      forbid_unless actor_present()
      authorize_if AshBilling.Checks.Subscribed
    end

    policy action_type(:read) do
      forbid_unless AshBilling.Checks.Subscribed
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action(:export_analytics) do
      forbid_unless {AshBilling.Checks.HasPrice, price: [@pro_price, @enterprise_price]}
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action(:enterprise_audit) do
      forbid_unless {AshBilling.Checks.HasPrice, price: @enterprise_price}
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action(:destroy) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end
end
