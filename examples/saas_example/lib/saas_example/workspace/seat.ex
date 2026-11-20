defmodule SaasExample.Workspace.Seat do
  @moduledoc """
  Team seat assignment resource protected by ownership policies and
  `AshBilling.Checks.Subscribed`.

  Seat count limits against `subscription.quantity` are enforced transactionally
  under a PostgreSQL `FOR UPDATE` row lock in `SaasExample.Workspace.assign_seat/2`.
  """
  use Ash.Resource,
    domain: SaasExample.Workspace,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "workspace_seats"
    repo SaasExample.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :owner_id, :uuid, allow_nil?: false, public?: true
    attribute :member_email, :ci_string, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:active, :revoked]],
      default: :active,
      allow_nil?: false,
      public?: true

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
      accept [:owner_id, :member_email, :status]
    end

    create :assign do
      accept [:member_email]
      change relate_actor(:owner)
      change set_attribute(:status, :active)
    end

    update :revoke do
      accept []
      require_atomic? false
      change set_attribute(:status, :revoked)
    end
  end

  policies do
    policy action(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:assign) do
      forbid_unless actor_present()
      authorize_if AshBilling.Checks.Subscribed
    end

    policy action_type(:read) do
      forbid_unless AshBilling.Checks.Subscribed
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action([:revoke, :destroy]) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end
end
