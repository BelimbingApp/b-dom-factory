defmodule Bilimbi.Factory.Inventory.TestPostingAuthority do
  @moduledoc """
  A posting authority for tests. It is compiled into Inventory's own OTP
  application, so it sits inside the Factory Domain container the way
  Production Execution does.

  Production Execution declares no authority yet, so `test_helper.exs`
  declares this one in Inventory's application metadata, where a real
  authority's `mix.exs` puts its own.
  """
end
