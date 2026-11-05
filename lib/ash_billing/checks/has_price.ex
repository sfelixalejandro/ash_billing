defmodule AshBilling.Checks.HasPrice do
  @moduledoc """
  An Ash policy check that authorizes if the current actor has an active subscription to a specific price or one of multiple allowed prices.

  Uses the actor snapshot and freshness rules of `AshBilling.Checks.Subscribed`.
  Multi-item subscriptions are outside the synchronized local model; unsupported
  updates retain the last supported state until application remediation.

  Requires a valid, non-empty `:price` identifier or a non-empty list of non-empty
  price identifiers. If `:price` is missing, nil, empty, whitespace-only, contains
  invalid elements, or is not a string/list of strings, authorization fails closed (denies access).

  ## Usage

      policies do
        # Single price
        policy action(:pro_feature) do
          authorize_if {AshBilling.Checks.HasPrice, price: "price_pro_tier"}
        end

        # Multiple allowed prices (e.g., Pro or Enterprise)
        policy action(:pro_or_enterprise_feature) do
          authorize_if {AshBilling.Checks.HasPrice, price: ["price_pro_tier", "price_enterprise_tier"]}
        end
      end
  """

  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def init(opts) do
    case Keyword.get(opts, :price) do
      price when is_binary(price) ->
        if String.trim(price) == "" do
          {:error, ":price in AshBilling.Checks.HasPrice must not be empty or whitespace-only"}
        else
          {:ok, opts}
        end

      [_ | _] = prices when is_list(prices) ->
        case validate_price_list(prices) do
          :ok ->
            {:ok, opts}

          {:error, reason} ->
            {:error, reason}
        end

      [] ->
        {:error, ":price list in AshBilling.Checks.HasPrice must not be empty"}

      nil ->
        {:error, ":price option is required for AshBilling.Checks.HasPrice"}

      other ->
        {:error,
         ":price in AshBilling.Checks.HasPrice must be a non-empty string or list of non-empty strings, got: #{inspect(other)}"}
    end
  end

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, opts) do
    case Keyword.get(opts, :price) do
      price when is_binary(price) ->
        trimmed = String.trim(price)

        if trimmed == "" do
          false
        else
          match_single_or_list(actor, context, opts, trimmed)
        end

      [_ | _] = prices when is_list(prices) ->
        case sanitize_price_list(prices) do
          {:ok, sanitized_prices} ->
            match_single_or_list(actor, context, opts, sanitized_prices)

          :error ->
            false
        end

      _ ->
        false
    end
  end

  @impl Ash.Policy.Check
  def describe(opts) do
    case Keyword.get(opts, :price) do
      price when is_binary(price) ->
        trimmed = String.trim(price)

        if trimmed == "" do
          "actor has an active subscription to <unspecified/invalid price>"
        else
          "actor has an active subscription to price #{trimmed}"
        end

      [_ | _] = prices when is_list(prices) ->
        case sanitize_price_list(prices) do
          {:ok, valid} ->
            "actor has an active subscription to one of prices #{Enum.join(valid, ", ")}"

          :error ->
            "actor has an active subscription to <unspecified/invalid price>"
        end

      _ ->
        "actor has an active subscription to <unspecified/invalid price>"
    end
  end

  defp match_single_or_list(actor, context, opts, price_or_prices) do
    domain = Keyword.get(opts, :domain) || Map.get(context, :domain)

    case actor do
      %_resource{} = record ->
        check_record_prices(record, price_or_prices, domain)

      _ ->
        false
    end
  end

  defp check_record_prices(record, price_or_prices, domain) do
    case record do
      %{subscriptions: subs} when is_list(subs) ->
        has_matching_subscription?(record, price_or_prices)

      %{subscriptions: %Ash.NotLoaded{}} when not is_nil(domain) ->
        case Ash.load(record, :subscriptions, domain: domain, authorize?: false) do
          {:ok, loaded} -> has_matching_subscription?(loaded, price_or_prices)
          _ -> false
        end

      _ ->
        has_matching_subscription?(record, price_or_prices)
    end
  end

  defp has_matching_subscription?(record, prices) when is_list(prices) do
    if Map.get(record, :billing_deleted_at) do
      false
    else
      case Map.get(record, :subscriptions) do
        subs when is_list(subs) ->
          price_set = MapSet.new(prices)

          Enum.any?(subs, fn sub ->
            AshBilling.subscribed?(%{subscriptions: [sub]}) and
              sub.price_id in price_set
          end)

        _ ->
          false
      end
    end
  end

  defp has_matching_subscription?(record, price) when is_binary(price) do
    AshBilling.subscribed?(record, price)
  end

  defp validate_price_list(prices) do
    Enum.reduce_while(prices, :ok, fn
      p, :ok when is_binary(p) ->
        if String.trim(p) == "" do
          {:halt,
           {:error,
            ":price list in AshBilling.Checks.HasPrice contains empty or whitespace-only strings"}}
        else
          {:cont, :ok}
        end

      invalid, :ok ->
        {:halt,
         {:error,
          ":price list in AshBilling.Checks.HasPrice must only contain strings, got: #{inspect(invalid)}"}}
    end)
  end

  defp sanitize_price_list(prices) do
    trimmed_prices =
      Enum.reduce_while(prices, [], fn
        p, acc when is_binary(p) ->
          trimmed = String.trim(p)
          if trimmed == "", do: {:halt, :error}, else: {:cont, [trimmed | acc]}

        _other, _acc ->
          {:halt, :error}
      end)

    case trimmed_prices do
      :error -> :error
      [] -> :error
      list -> {:ok, Enum.reverse(list)}
    end
  end
end
