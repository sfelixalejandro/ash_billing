import Config

if config_env() != :test do
  if db_url = System.get_env("DATABASE_URL") do
    config :saas_example, SaasExample.Repo,
      url: db_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
  end

  if secret_key_base = System.get_env("SECRET_KEY_BASE") do
    config :saas_example, SaasExampleWeb.Endpoint, secret_key_base: secret_key_base
  end

  if api_key = System.get_env("STRIPE_API_KEY") do
    if String.starts_with?(api_key, "sk_live_") and
         System.get_env("ALLOW_STRIPE_LIVE_MODE") != "true" do
      raise """
      Refusing to start saas_example with a live Stripe API key (sk_live_...).
      Use a Stripe Test Mode key (sk_test_...) or explicitly set ALLOW_STRIPE_LIVE_MODE=true.
      """
    end

    config :ash_billing, :api_key, api_key
  end

  if webhook_secret = System.get_env("STRIPE_WEBHOOK_SECRET") do
    config :ash_billing, :webhook_secret, webhook_secret
  end

  expected_livemode =
    case System.get_env("STRIPE_EXPECTED_LIVEMODE") do
      "true" -> true
      "false" -> false
      nil -> false
      other -> raise "Invalid STRIPE_EXPECTED_LIVEMODE=#{inspect(other)}; expected true or false"
    end

  config :ash_billing, :expected_livemode, expected_livemode
end
