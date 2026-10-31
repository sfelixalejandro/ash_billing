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

    test "HasPrice fail-closed behavior for missing, empty or invalid price configuration" do
      {:ok, user} = Ash.create(User, %{email: "subscriber_pro@example.com"}, domain: Domain)

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_pro_failclosed",
            status: :active,
            price_id: "price_pro"
          },
          domain: Domain
        )

      user = Ash.load!(user, :subscriptions, domain: Domain)

      # Valid explicit price matches
      assert AshBilling.Checks.HasPrice.match?(user, %{}, price: "price_pro") == true

      # Mismatched price denies
      assert AshBilling.Checks.HasPrice.match?(user, %{}, price: "price_enterprise") == false

      # Missing, nil, empty, whitespace-only and invalid price types fail closed (deny access)
      assert AshBilling.Checks.HasPrice.match?(user, %{}, []) == false
      assert AshBilling.Checks.HasPrice.match?(user, %{}, price: nil) == false
      assert AshBilling.Checks.HasPrice.match?(user, %{}, price: "") == false
      assert AshBilling.Checks.HasPrice.match?(user, %{}, price: "   ") == false
      assert AshBilling.Checks.HasPrice.match?(user, %{}, price: :invalid_atom) == false
      assert AshBilling.Checks.HasPrice.match?(user, %{}, price: 12345) == false

      # No subscription denies access even if price is valid
      {:ok, free_user} = Ash.create(User, %{email: "nosub@example.com"}, domain: Domain)
      free_user = Ash.load!(free_user, :subscriptions, domain: Domain)
      assert AshBilling.Checks.HasPrice.match?(free_user, %{}, price: "price_pro") == false

      # Subscribed check without a price still permits active subscriber
      assert AshBilling.Checks.Subscribed.match?(user, %{}, []) == true

      # Compile-time validation via init/1 raises error on invalid configuration
      assert {:ok, _} = AshBilling.Checks.HasPrice.init(price: "price_pro")
      assert {:error, _} = AshBilling.Checks.HasPrice.init([])
      assert {:error, _} = AshBilling.Checks.HasPrice.init(price: nil)
      assert {:error, _} = AshBilling.Checks.HasPrice.init(price: "")
      assert {:error, _} = AshBilling.Checks.HasPrice.init(price: "   ")
      assert {:error, _} = AshBilling.Checks.HasPrice.init(price: 123)
    end
  end
end
