defmodule SaasExample.Security do
  @moduledoc """
  Runtime security guards for `SaasExample`.

  Prevents accidental production startup with development/placeholder secrets,
  guards against unintended Stripe Live Mode credentials, and blocks demo seed
  accounts (with well-known passwords) from being created outside local demo/dev
  environments.
  """

  @min_secret_key_base_bytes 64

  @forbidden_secret_markers [
    "dev_only",
    "test_only",
    "replace_with",
    "changeme",
    "placeholder"
  ]

  @doc """
  Verifies endpoint and billing secrets for the given environment.
  Raises on insecure production configuration.
  """
  @spec verify_runtime_config!(keyword()) :: :ok
  def verify_runtime_config!(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, fn -> current_env() end)

    secret_key_base =
      Keyword.get_lazy(opts, :secret_key_base, fn ->
        :saas_example
        |> Application.get_env(SaasExampleWeb.Endpoint, [])
        |> Keyword.get(:secret_key_base)
      end)

    api_key =
      Keyword.get_lazy(opts, :api_key, fn ->
        Application.get_env(:ash_billing, :api_key)
      end)

    allow_live? =
      Keyword.get_lazy(opts, :allow_stripe_live_mode?, fn ->
        System.get_env("ALLOW_STRIPE_LIVE_MODE") == "true"
      end)

    validate_secret_key_base!(env, secret_key_base)
    validate_stripe_api_key!(api_key, allow_live?)
    :ok
  end

  @doc """
  Ensures demo accounts with well-known passwords are ONLY seeded in `:dev`
  (or an explicitly opted-in non-production demo environment). Always fails closed
  in `:prod`.
  """
  @spec ensure_demo_seeds_allowed!(keyword()) :: :ok
  def ensure_demo_seeds_allowed!(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, fn -> current_env() end)

    allow_demo? =
      Keyword.get_lazy(opts, :allow_demo_seeds?, fn ->
        System.get_env("ALLOW_DEMO_SEEDS") == "true"
      end)

    cond do
      env == :prod ->
        raise """
        Refusing to seed demo accounts with well-known passwords in :prod environment.
        Create production administrators explicitly with strong credentials instead.
        """

      env == :dev or allow_demo? ->
        :ok

      true ->
        raise """
        Refusing to seed demo accounts in #{inspect(env)} environment.
        Demo seeds are restricted to :dev (or non-prod environments with ALLOW_DEMO_SEEDS=true).
        """
    end
  end

  @spec current_env() :: atom()
  def current_env do
    Application.get_env(:saas_example, :env, :dev)
  end

  defp validate_secret_key_base!(env, secret) when env in [:dev, :test] do
    if is_binary(secret) and byte_size(secret) >= @min_secret_key_base_bytes do
      :ok
    else
      raise "Missing or short :secret_key_base (must be at least #{@min_secret_key_base_bytes} bytes)"
    end
  end

  defp validate_secret_key_base!(env, secret) do
    cond do
      not is_binary(secret) or byte_size(secret) < @min_secret_key_base_bytes ->
        raise """
        Refusing to start saas_example in #{inspect(env)} without a strong SECRET_KEY_BASE
        (at least #{@min_secret_key_base_bytes} bytes; generate with `mix phx.gen.secret`).
        """

      contains_forbidden_marker?(secret) ->
        raise """
        Refusing to start saas_example in #{inspect(env)} with a development or placeholder SECRET_KEY_BASE.
        Generate a cryptographically random secret with `mix phx.gen.secret`.
        """

      true ->
        :ok
    end
  end

  defp validate_stripe_api_key!(api_key, allow_live?) do
    if is_binary(api_key) and String.starts_with?(api_key, "sk_live_") and not allow_live? do
      raise """
      Refusing to start saas_example with a live Stripe API key (sk_live_...).
      Use Stripe Test Mode (sk_test_...) or explicitly set ALLOW_STRIPE_LIVE_MODE=true.
      """
    end

    :ok
  end

  defp contains_forbidden_marker?(secret) do
    downcased = String.downcase(secret)
    Enum.any?(@forbidden_secret_markers, &String.contains?(downcased, &1))
  end
end
