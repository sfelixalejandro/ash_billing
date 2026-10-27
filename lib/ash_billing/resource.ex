defmodule AshBilling.Resource do
  @moduledoc """
  A Spark DSL extension for Ash resources representing billing customers (e.g., `User` or `Organization`).

  ## Usage

      defmodule MyApp.Accounts.User do
        use Ash.Resource,
          domain: MyApp.Accounts,
          extensions: [AshBilling.Resource]

        billing do
          customer_id_attribute :stripe_customer_id
          provider AshBilling.Providers.Stripe
        end
      end
  """

  @billing %Spark.Dsl.Section{
    name: :billing,
    describe: "Configuration for billing customer functionality.",
    schema: [
      customer_id_attribute: [
        type: :atom,
        default: :stripe_customer_id,
        doc: "The attribute name on the resource that stores the billing customer ID."
      ],
      provider: [
        type: {:behaviour, AshBilling.Provider},
        default: AshBilling.Providers.Stripe,
        doc: "The billing provider module."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@billing],
    transformers: [AshBilling.Resource.Transformers.AddCustomerIdAttribute],
    verifiers: [AshBilling.Resource.Verifiers.VerifyCustomerIdAttribute]
end
