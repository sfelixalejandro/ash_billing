defmodule AshBilling.Subscription do
  @moduledoc """
  A Spark DSL extension for Ash resources storing subscriptions in the database.

  ## Usage

      defmodule MyApp.Billing.Subscription do
        use Ash.Resource,
          domain: MyApp.Billing,
          extensions: [AshBilling.Subscription]

        billing_subscription do
          customer_relationship :user
          provider AshBilling.Providers.Stripe
        end
      end
  """

  @billing_subscription %Spark.Dsl.Section{
    name: :billing_subscription,
    describe: "Configuration for billing subscription resources.",
    schema: [
      provider: [
        type: {:behaviour, AshBilling.Provider},
        default: AshBilling.Providers.Stripe,
        doc: "The billing provider module."
      ],
      customer_relationship: [
        type: :atom,
        doc: "The relationship linking to the customer resource."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@billing_subscription],
    transformers: [AshBilling.Subscription.Transformers.AddSubscriptionAttributes],
    verifiers: [AshBilling.Subscription.Verifiers.VerifyCustomerRelationship]
end
