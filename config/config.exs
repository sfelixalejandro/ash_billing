import Config

config :ash,
  default_string_length_count: :codepoints

if config_env() == :test do
  config :ash_billing,
    ash_domains: [
      AshBilling.Test.Domain,
      AshBilling.Test.PostgresDomain
    ],
    ecto_repos: [AshBilling.Test.Repo]

  config :ash_billing, AshBilling.Test.Repo,
    database: System.get_env("POSTGRES_DB", "ash_billing_test"),
    username: System.get_env("POSTGRES_USER", System.get_env("USER", "postgres")),
    password: System.get_env("POSTGRES_PASSWORD", ""),
    hostname: System.get_env("POSTGRES_HOST", "localhost"),
    port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
end
