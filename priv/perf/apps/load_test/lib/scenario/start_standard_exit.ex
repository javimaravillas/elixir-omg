# Copyright 2019-2020 OmiseGO Pte Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule LoadTest.Scenario.StartStandardExit do
  @moduledoc """
  Starts a standard exit.

  ## configuration values
  - `exiter` the account that's starting the exit
  - `utxo` the utxo to exit
  """

  use Chaperon.Scenario

  alias LoadTest.ChildChain.Exit
  alias LoadTest.Ethereum.Account
  alias LoadTest.Service.Faucet

  def run(session) do
    exiter = config(session, [:exiter])
    utxo = config(session, [:utxo])
    gas_price = config(session, [:gas_price])
    exit_utxo(utxo, exiter, gas_price)
    session
  end

  def exit_utxo(utxo, exiter, gas_price) do
    utxo
    |> Exit.wait_for_exit_data()
    |> Exit.start_exit(exiter, gas_price)
  end
end
