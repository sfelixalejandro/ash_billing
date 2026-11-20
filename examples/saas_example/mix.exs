defmodule SaasExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :saas_example,
      version: "0.7.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SaasExample.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash_billing, path: "../.."},
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.15"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:simple_sat, "~> 0.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "billing.doctor": [
        "ash_billing.doctor --customer-resource SaasExample.Accounts.User --subscription-resource SaasExample.Billing.Subscription --deduplication-resource SaasExample.Billing.WebhookEvent"
      ],
      "billing.reconcile.dry_run": [
        "ash_billing.reconcile --domain SaasExample.Billing --subscription-resource SaasExample.Billing.Subscription --customer-resource SaasExample.Accounts.User --older-than-hours 24 --system"
      ]
    ]
  end
end
