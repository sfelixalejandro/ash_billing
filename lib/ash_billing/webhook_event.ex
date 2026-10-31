defmodule AshBilling.WebhookEvent do
  @moduledoc """
  A Spark DSL extension for Ash resources representing processed webhook events.

  Used for multi-node / distributed webhook deduplication across clustered application servers.

  > ### Security Notice
  > `AshBilling.WebhookEvent` is an internal deduplication resource. Its actions
  > must remain internal to the application and must **never** be exposed through
  > public APIs (such as `AshJsonApi`, `AshGraphql`, or public user forms), as mutating
  > internal deduplication fields (`status`, `lease_token`, etc.) could compromise webhook integrity.

  ## Usage

      defmodule MyApp.Billing.WebhookEvent do
        use Ash.Resource,
          domain: MyApp.Billing,
          extensions: [AshBilling.WebhookEvent]

        actions do
          default_accept :*
          defaults [:read, :create, :update, :destroy]
        end
      end
  """

  @webhook_event %Spark.Dsl.Section{
    name: :billing_webhook_event,
    describe: "Configuration for billing webhook event deduplication.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@webhook_event],
    transformers: [AshBilling.WebhookEvent.Transformers.AddWebhookEventAttributes]
end
