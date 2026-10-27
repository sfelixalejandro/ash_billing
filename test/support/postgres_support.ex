defmodule AshBilling.Test.Repo do
  use AshPostgres.Repo,
    otp_app: :ash_billing,
    warn_on_missing_ash_functions?: false

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  def installed_extensions do
    ["uuid-ossp", "citext"]
  end
end

defmodule AshBilling.Test.PostgresWebhookEvent do
  use Ash.Resource,
    domain: AshBilling.Test.PostgresDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "webhook_events"
    repo(AshBilling.Test.Repo)
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end

defmodule AshBilling.Test.PostgresDomain do
  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshBilling.Test.PostgresWebhookEvent
  end
end
