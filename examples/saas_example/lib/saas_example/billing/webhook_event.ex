defmodule SaasExample.Billing.WebhookEvent do
  @moduledoc """
  Private PostgreSQL webhook deduplication ledger managed by `AshBilling.Deduplication`.

  Intentionally NOT exposed via AshJsonApi or AshGraphql.
  """
  use Ash.Resource,
    domain: SaasExample.Billing,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "webhook_events"
    repo SaasExample.Repo
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end
