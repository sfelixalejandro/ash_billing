defmodule AshBilling.Subscription do
  @moduledoc """
  A Spark DSL extension for Ash resources storing subscriptions in the database.

  Provider subscription IDs are unique within this resource and its Ash tenant.
  Each scope must use one provider/account/environment. PostgreSQL consumers must
  generate and apply a migration for the injected identity, resolving existing duplicates first.

  Billing state is not implicitly accepted by wildcard create/update actions.
  Explicitly named inputs remain an application authorization decision. Internal
  webhook writes retain actions, policies, validations and tenant scope.

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
    transformers: [
      AshBilling.Subscription.Transformers.AddSubscriptionAttributes,
      AshBilling.Transformers.ProtectBillingAttributes
    ],
    verifiers: [AshBilling.Subscription.Verifiers.VerifyCustomerRelationship]
end
