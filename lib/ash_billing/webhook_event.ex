defmodule AshBilling.WebhookEvent do
  @moduledoc """
  A Spark DSL extension for Ash resources representing processed webhook events.

  Used for multi-node / distributed webhook deduplication across clustered application servers.

  ## Usage

      defmodule MyApp.Billing.WebhookEvent do
        use Ash.Resource,
          domain: MyApp.Billing,
          extensions: [AshBilling.WebhookEvent]
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
