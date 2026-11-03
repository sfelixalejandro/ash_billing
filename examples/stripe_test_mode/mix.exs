defmodule AshBillingConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_billing_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps_path: "../../deps",
      build_path: "../../_build/stripe_consumer",
      deps: [
        {:ash_billing, path: "../.."},
        {:ash_postgres, "~> 2.15"},
        {:bandit, "~> 1.5"},
        {:simple_sat, "~> 0.1"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {AshBillingConsumer.Application, []}]
  end
end
