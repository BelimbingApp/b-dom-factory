defmodule Bilimbi.Factory.ProductionExecution.Capture do
  @moduledoc false

  # Shared rules for shop-floor capture (wastage, labour, measurements): the
  # recorder is always the Scope's authenticated user in the order's company,
  # never a caller-named actor; an impersonated session is refused; and each
  # write is decided by Base Authz against the production order before any
  # transaction opens, so a refusal keeps its decision log.

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Scope

  @text_limit 10_000

  def recorder(%Scope{} = scope, company_id) do
    case {Scope.actor(scope), Authz.scope_actor(scope)} do
      {%{impersonator_id: nil}, {:ok, %Authz.Actor{company_id: ^company_id} = actor}} ->
        {:ok,
         %{
           recorded_by_type: Authz.Actor.principal_type(actor),
           recorded_by_id: actor.id,
           recorded_by_acting_for_user_id: actor.acting_for_user_id
         }}

      {%{impersonator_id: nil}, {:ok, _actor}} ->
        {:error, :recorder_company_mismatch}

      {%{impersonator_id: nil}, {:error, :no_authenticated_actor}} ->
        {:error, :recorder_required}

      _impersonated ->
        {:error, :capture_refused_under_impersonation}
    end
  end

  def authorize(%Scope{} = scope, company_id, order_id, capability) do
    resource =
      Authz.resource("factory.production_order", order_id, company_id: company_id, scope: scope)

    if Authz.can(scope, capability, resource).allowed,
      do: :ok,
      else: {:error, :capture_not_authorized}
  end

  def allowed?(%Scope{} = scope, company_id, order_id, capability),
    do: authorize(scope, company_id, order_id, capability) == :ok

  def request_id(value) do
    if is_binary(value) and String.trim(value) != "" and byte_size(value) <= 240,
      do: {:ok, value},
      else: {:error, :invalid_request_id}
  end

  def fingerprint(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "An optional free-text value: nil or blank is nil, otherwise trimmed."
  def optional_text(nil), do: {:ok, nil}

  def optional_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      trimmed when byte_size(trimmed) <= @text_limit -> {:ok, trimmed}
      _ -> :error
    end
  end

  def optional_text(_text), do: :error

  def required_text(text) do
    case optional_text(text) do
      {:ok, nil} -> :error
      result -> result
    end
  end

  @doc "A decimal of at most 12 places and below 10^12, as numeric(24, 12) stores it."
  def decimal(value) when is_binary(value) or is_integer(value) or is_struct(value, Decimal) do
    case Decimal.cast(value) do
      {:ok, decimal} ->
        cond do
          Decimal.nan?(decimal) or Decimal.inf?(decimal) -> :error
          not Decimal.eq?(Decimal.round(decimal, 12), decimal) -> :error
          Decimal.compare(Decimal.abs(decimal), Decimal.new("1E12")) != :lt -> :error
          true -> {:ok, Decimal.normalize(decimal)}
        end

      :error ->
        :error
    end
  end

  def decimal(value) when is_float(value), do: value |> Float.to_string() |> decimal()
  def decimal(_value), do: :error

  @doc "A caller's time for a past event: nil is now, and a future time is refused."
  def past_time(nil, now), do: {:ok, now}

  def past_time(%DateTime{} = at, now) do
    if DateTime.compare(at, now) == :gt, do: :error, else: {:ok, at}
  end

  def past_time(_at, _now), do: :error

  def value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
