defmodule AshBilling.Providers.Stripe do
  @moduledoc """
  Stripe implementation of `AshBilling.Provider`.
  """

  @behaviour AshBilling.Provider

  @default_base_url "https://api.stripe.com"
  @default_tolerance 300

  @impl true
  def create_customer(params, opts \\ []) do
    req = build_req(opts)
    form_params = to_form_params(params)

    case Req.post(req, url: "/v1/customers", form: form_params) do
      {:ok, %{status: 200, body: %{"id" => id}}} ->
        {:ok, id}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: extract_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def create_checkout_session(params, opts \\ []) do
    req = build_req(opts)
    form_params = to_form_params(params)

    case Req.post(req, url: "/v1/checkout/sessions", form: form_params) do
      {:ok, %{status: 200, body: %{"id" => id, "url" => url}}} ->
        {:ok, %{id: id, url: url}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: extract_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def create_portal_session(params, opts \\ []) do
    req = build_req(opts)
    form_params = to_form_params(params)

    case Req.post(req, url: "/v1/billing_portal/sessions", form: form_params) do
      {:ok, %{status: 200, body: %{"url" => url}}} ->
        {:ok, %{url: url}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: extract_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_subscription(subscription_id, opts \\ []) do
    req = build_req(opts)

    case Req.get(req, url: "/v1/subscriptions/#{subscription_id}") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: extract_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def cancel_subscription(subscription_id, opts \\ []) do
    req = build_req(opts)
    at_period_end? = Keyword.get(opts, :at_period_end, true)

    result =
      if at_period_end? do
        Req.post(req,
          url: "/v1/subscriptions/#{subscription_id}",
          form: [{"cancel_at_period_end", "true"}]
        )
      else
        Req.delete(req, url: "/v1/subscriptions/#{subscription_id}")
      end

    case result do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: extract_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def resume_subscription(subscription_id, opts \\ []) do
    req = build_req(opts)

    case Req.post(req,
           url: "/v1/subscriptions/#{subscription_id}",
           form: [{"cancel_at_period_end", "false"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: extract_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def swap_plan(subscription_id, new_price_id, opts \\ []) do
    req = build_req(opts)
    proration_behavior = Keyword.get(opts, :proration_behavior, "create_prorations")

    with {:ok, item_id} <- resolve_subscription_item_id(subscription_id, opts) do
      item_params =
        %{"id" => item_id, "price" => new_price_id}
        |> then(fn p ->
          if qty = Keyword.get(opts, :quantity), do: Map.put(p, "quantity", qty), else: p
        end)

      params =
        %{
          "items" => [item_params],
          "proration_behavior" => to_string(proration_behavior)
        }
        |> then(fn p ->
          if p_date = Keyword.get(opts, :proration_date),
            do: Map.put(p, "proration_date", p_date),
            else: p
        end)

      form_params = to_form_params(params)

      case Req.post(req, url: "/v1/subscriptions/#{subscription_id}", form: form_params) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, error: extract_error(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_subscription_item_id(subscription_id, opts) when is_list(opts) do
    case Keyword.get(opts, :subscription_item_id) do
      item_id when is_binary(item_id) and item_id != "" ->
        {:ok, item_id}

      _ ->
        case get_subscription(subscription_id, opts) do
          {:ok, %{"items" => %{"data" => [%{"id" => id} | _]}}} ->
            {:ok, id}

          {:ok, body} ->
            {:error, {:missing_subscription_item, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def verify_webhook(payload, signature_header, secret, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)

    with {:ok, header} when is_binary(header) <- extract_signature_header(signature_header),
         {:ok, timestamp, signature} <- parse_header(header),
         :ok <- verify_timestamp(timestamp, tolerance),
         :ok <- verify_signature(payload, timestamp, signature, secret),
         {:ok, event} <- Jason.decode(payload) do
      {:ok, event}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Helpers

  defp extract_signature_header(nil), do: {:error, :missing_signature_header}
  defp extract_signature_header(header) when is_binary(header), do: {:ok, header}

  defp parse_header(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(fn parts -> length(parts) == 2 end)
      |> Map.new(fn [k, v] -> {String.trim(k), String.trim(v)} end)

    case {Map.get(parts, "t"), Map.get(parts, "v1")} do
      {t, v1} when is_binary(t) and is_binary(v1) ->
        case Integer.parse(t) do
          {timestamp, ""} -> {:ok, timestamp, v1}
          _ -> {:error, :invalid_timestamp_in_header}
        end

      _ ->
        {:error, :invalid_signature_header}
    end
  end

  defp verify_timestamp(timestamp, tolerance) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= tolerance do
      :ok
    else
      {:error, :timestamp_outside_tolerance}
    end
  end

  defp verify_signature(payload, timestamp, signature, secret) do
    signed_payload = "#{timestamp}.#{payload}"

    expected_signature =
      :crypto.mac(:hmac, :sha256, secret, signed_payload)
      |> Base.encode16(case: :lower)

    if byte_size(expected_signature) == byte_size(signature) and
         :crypto.hash_equals(expected_signature, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp build_req(opts) do
    base_url =
      Keyword.get(
        opts,
        :base_url,
        Application.get_env(:ash_billing, :stripe_base_url, @default_base_url)
      )

    api_key =
      opts
      |> Keyword.get(
        :api_key,
        Application.get_env(:ash_billing, :stripe_api_key) ||
          System.get_env("STRIPE_SECRET_KEY")
      )
      |> resolve_key()

    req_opts = Keyword.get(opts, :req_opts, [])

    idemp_header =
      case Keyword.get(opts, :idempotency_key) do
        nil -> []
        key when is_binary(key) -> [{"idempotency-key", key}]
      end

    base_opts = [base_url: base_url, headers: idemp_header]

    base_opts =
      if api_key && api_key != "", do: [{:auth, {:bearer, api_key}} | base_opts], else: base_opts

    base_opts
    |> Keyword.merge(req_opts)
    |> Req.new()
  end

  defp resolve_key({module, function, args}) when is_atom(module) and is_atom(function) do
    apply(module, function, args)
  end

  defp resolve_key(fun) when is_function(fun, 0), do: fun.()
  defp resolve_key(key) when is_binary(key), do: key
  defp resolve_key(_), do: nil

  defp extract_error(%{"error" => %{"message" => message}}), do: message
  defp extract_error(body), do: body

  @doc false
  def to_form_params(data, prefix \\ nil)

  def to_form_params(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      new_prefix = if prefix, do: "#{prefix}[#{key}]", else: "#{key}"
      to_form_params(value, new_prefix)
    end)
  end

  def to_form_params(list, prefix) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      new_prefix = "#{prefix}[#{index}]"
      to_form_params(value, new_prefix)
    end)
  end

  def to_form_params(value, prefix) do
    [{prefix, to_string(value)}]
  end
end
