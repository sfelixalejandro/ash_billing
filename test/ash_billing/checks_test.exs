defmodule AshBilling.ChecksTest do
  use ExUnit.Case, async: true

  alias AshBilling.Test.{Domain, PremiumFeature, Subscription, User}

  describe "AshBilling.Checks.Subscribed and HasPrice policies" do
    test "denies access when actor has no subscription" do
      {:ok, user} = Ash.create(User, %{email: "free_user@example.com"}, domain: Domain)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(PremiumFeature, %{title: "Doc 1"},
                 actor: user,
                 domain: Domain
               )
    end

    test "authorizes access when actor has an active subscription" do
      {:ok, user} = Ash.create(User, %{email: "subscriber@example.com"}, domain: Domain)

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_check_active",
            status: :active,
            price_id: "price_basic"
          },
          domain: Domain
        )

      user = Ash.load!(user, :subscriptions, domain: Domain)

      assert {:ok, feature} =
               Ash.create(PremiumFeature, %{title: "Doc 1"},
                 actor: user,
                 domain: Domain
               )

      assert feature.title == "Doc 1"
    end

    test "authorizes access when actor is on trial" do
      {:ok, user} = Ash.create(User, %{email: "trial_user@example.com"}, domain: Domain)

      future_date = DateTime.utc_now() |> DateTime.add(7, :day)

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_check_trial",
            status: :trialing,
            price_id: "price_basic",
            trial_ends_at: future_date
          },
          domain: Domain
        )

      user = Ash.load!(user, :subscriptions, domain: Domain)

      assert {:ok, _feature} =
               Ash.create(PremiumFeature, %{title: "Trial Doc"},
                 actor: user,
                 domain: Domain
               )
    end

    test "denies access when subscription is canceled" do
      {:ok, user} = Ash.create(User, %{email: "canceled@example.com"}, domain: Domain)

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_check_canceled",
            status: :canceled,
            price_id: "price_basic"
          },
          domain: Domain
        )

      user = Ash.load!(user, :subscriptions, domain: Domain)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(PremiumFeature, %{title: "Doc 2"},
                 actor: user,
                 domain: Domain
               )
    end

    test "enforces price/tier requirements with HasPrice" do
      {:ok, user} = Ash.create(User, %{email: "basic_user@example.com"}, domain: Domain)

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_check_basic",
            status: :active,
            price_id: "price_basic"
          },
          domain: Domain
        )

      user = Ash.load!(user, :subscriptions, domain: Domain)

      # Allowed for general subscribed check
      assert {:ok, _} =
               Ash.create(PremiumFeature, %{title: "Allowed"},
                 actor: user,
                 domain: Domain
               )

      # Forbidden for price_pro check
      assert {:error, %Ash.Error.Forbidden{}} =
               PremiumFeature
               |> Ash.Query.for_read(:pro_only)
               |> Ash.read(actor: user, domain: Domain)

      # Upgrade user to price_pro
      {:ok, _sub_pro} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_check_pro",
            status: :active,
            price_id: "price_pro"
          },
          domain: Domain
        )

      user_pro = Ash.load!(user, :subscriptions, domain: Domain)

      assert {:ok, _} =
               PremiumFeature
               |> Ash.Query.for_read(:pro_only)
               |> Ash.read(actor: user_pro, domain: Domain)
    end

    test "lazy-loads subscriptions when actor subscriptions are not preloaded" do
      {:ok, user} = Ash.create(User, %{email: "lazy_load@example.com"}, domain: Domain)

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_check_lazy",
            status: :active,
            price_id: "price_basic"
          },
          domain: Domain
        )

      # user here has subscriptions: %Ash.NotLoaded{}
      assert %Ash.NotLoaded{} = user.subscriptions

      # Check policy still succeeds because it lazy-loads via domain in context
      assert {:ok, _feature} =
               Ash.create(PremiumFeature, %{title: "Lazy Doc"},
                 actor: user,
                 domain: Domain
               )
    end

    test "check description outputs clear information" do
      assert AshBilling.Checks.Subscribed.describe([]) == "actor has an active subscription"

      assert AshBilling.Checks.Subscribed.describe(price: "price_pro") ==
               "actor has an active subscription to price_pro"

      assert AshBilling.Checks.HasPrice.describe(price: "price_pro") ==
               "actor has an active subscription to price price_pro"
    end

    test "handles nil and non-struct actors safely" do
      assert AshBilling.Checks.Subscribed.match?(nil, %{}, []) == false
      assert AshBilling.Checks.Subscribed.match?("not_a_struct", %{}, []) == false
      assert AshBilling.Checks.Subscribed.match?(%{some: :map}, %{}, []) == false

      # Struct without subscriptions relationship
      {:ok, custom_user} =
        Ash.create(AshBilling.Test.CustomUser, %{email: "cust@saas.com"}, domain: Domain)

      assert AshBilling.Checks.Subscribed.match?(custom_user, %{}, []) == false
    end
  end
end
