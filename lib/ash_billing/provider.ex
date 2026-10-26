defmodule AshBilling.Provider do
  @moduledoc """
  Defines the behavior for billing providers (Stripe, Paddle, LemonSqueezy, etc.).
  """

  @type customer_id :: String.t()
  @type subscription_id :: String.t()
  @type session_url :: String.t()
  @type session_id :: String.t()
  @type opts :: keyword()

  @doc """
  Creates a customer in the billing provider.
  """
  @callback create_customer(params :: map(), opts :: opts()) ::
              {:ok, customer_id()} | {:error, term()}

  @doc """
  Creates a checkout session for subscriptions or one-time payments.
  """
  @callback create_checkout_session(params :: map(), opts :: opts()) ::
              {:ok, %{url: session_url(), id: session_id()}} | {:error, term()}

  @doc """
  Creates a billing portal session where customers can manage their payment methods and subscriptions.
  """
  @callback create_portal_session(params :: map(), opts :: opts()) ::
              {:ok, %{url: session_url()}} | {:error, term()}

  @doc """
  Retrieves a subscription from the billing provider.
  """
  @callback get_subscription(subscription_id(), opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Cancels a subscription in the billing provider.
  """
  @callback cancel_subscription(subscription_id(), opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Resumes a subscription that was scheduled to cancel at period end.
  """
  @callback resume_subscription(subscription_id(), opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Swaps an active subscription to a new price/plan, with optional proration behavior.
  """
  @callback swap_plan(subscription_id(), new_price_id :: String.t(), opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Verifies an incoming webhook payload and signature.
  Returns `{:ok, event_map}` if valid, or `{:error, reason}` if invalid.
  """
  @callback verify_webhook(
              payload :: binary(),
              signature_header :: String.t() | nil,
              secret :: String.t(),
              opts :: opts()
            ) :: {:ok, map()} | {:error, term()}
end
