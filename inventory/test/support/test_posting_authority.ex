defmodule Bilimbi.Factory.Inventory.TestPostingAuthority do
  @moduledoc """
  A posting authority for tests. It is compiled into Inventory's own OTP
  application, so it sits inside the Factory Domain container the way
  Production Execution does.

  Production Execution declares no authority yet, so Inventory's `mix.exs`
  declares this one in its test application metadata, the way a real
  authority's `mix.exs` declares its own.
  """
end
