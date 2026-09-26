defmodule Bilimbi.Factory.Inventory.TestPostingAuthority do
  @moduledoc """
  A posting authority for tests. It is compiled into Inventory's own OTP
  application, so it sits inside the Factory Domain container the way
  Production Execution does.

  `test_helper.exs` registers it once and keeps its credential, as a real
  authority keeps its own.
  """

  @key {__MODULE__, :credential}

  def register! do
    {:ok, credential} = Bilimbi.Factory.Inventory.register_posting_authority(__MODULE__)
    :persistent_term.put(@key, credential)
  end

  def credential, do: :persistent_term.get(@key)
end
