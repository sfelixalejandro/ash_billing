defmodule AshBilling.MixProject do
  use Mix.Project

  @version "0.1.2"
  @description "Declarative billing, subscriptions, and payment providers for the Ash Framework."
  @source_url "https://github.com/sfelixalejandro/ash_billing"

  def project do
    [
      app: :ash_billing,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      package: package(),
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      test_coverage: [
        summary: [threshold: 90],
        ignore_modules: [
          ~r/^Inspect\./,
          ~r/\.Transformers\./,
          ~r/\.Options$/,
          ~r/^AshBilling\.Test(\.|$)/
        ]
      ],
      deps: deps(),
      docs: &docs/0,
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {AshBilling.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: "ash_billing",
      maintainers: ["Alejandro Felix <SFelixAlejandro@hotmail.com>"],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* documentation),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Discord" => "https://discord.gg/HTHRaaVPUc",
        "Forum" => "https://elixirforum.com/c/ash-framework-forum/",
        "Website" => "https://ash-hq.org"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.14"},
      {:telemetry, "~> 1.0"},
      {:igniter, ">= 0.5.0", optional: true},
      # Dev & Test
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:simple_sat, ">= 0.0.0", only: [:dev, :test]},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "spark.cheat_sheets":
        "spark.cheat_sheets --extensions AshBilling.Resource,AshBilling.Subscription,AshBilling.WebhookEvent",
      "spark.formatter":
        "spark.formatter --extensions AshBilling.Resource,AshBilling.Subscription,AshBilling.WebhookEvent",
      docs: [
        "spark.cheat_sheets",
        "docs"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extra_section: "GUIDES",
      extras: [
        {"README.md", title: "Home"},
        {"documentation/tutorials/getting-started-with-ash-billing.md",
         title: "Getting Started with AshBilling"},
        {"documentation/topics/webhooks-and-resilience.md",
         title: "Webhooks & Operational Resilience"},
        {"documentation/dsls/DSL-AshBilling.Resource.md",
         search_data: Spark.Docs.search_data_for(AshBilling.Resource)},
        {"documentation/dsls/DSL-AshBilling.Subscription.md",
         search_data: Spark.Docs.search_data_for(AshBilling.Subscription)},
        {"documentation/dsls/DSL-AshBilling.WebhookEvent.md",
         search_data: Spark.Docs.search_data_for(AshBilling.WebhookEvent)},
        "CHANGELOG.md",
        "SECURITY.md",
        ".github/CONTRIBUTING.md"
      ],
      groups_for_extras: [
        Tutorials: ~r"documentation/tutorials",
        Topics: ~r"documentation/topics",
        DSLs: ~r"documentation/dsls"
      ],
      groups_for_modules: [
        Core: [
          AshBilling,
          AshBilling.Provider,
          AshBilling.Plug,
          AshBilling.WebhookSync,
          AshBilling.Deduplication
        ],
        "Policy Checks": [
          AshBilling.Checks.Subscribed,
          AshBilling.Checks.HasPrice
        ],
        Providers: [
          AshBilling.Providers.Stripe
        ],
        "DSL & Extensions": [
          AshBilling.Resource,
          AshBilling.Resource.Info,
          AshBilling.Subscription,
          AshBilling.Subscription.Info,
          AshBilling.WebhookEvent
        ],
        "Mix Tasks": [
          Mix.Tasks.AshBilling.Install
        ]
      ]
    ]
  end
end
