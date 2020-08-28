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

defmodule OMG.WatcherInfo.API.Transaction do
  @moduledoc """
  Module provides API for transactions
  """

  alias OMG.Crypto
  alias OMG.State.Transaction
  alias OMG.TypedDataHash
  alias OMG.Utils.Paginator
  alias OMG.Utxo
  alias OMG.WatcherInfo.DB
  alias OMG.WatcherInfo.HttpRPC.Client
  alias OMG.WatcherInfo.Transaction, as: TransactionCreator
  alias OMG.WatcherInfo.UtxoSelection

  require Utxo
  require Transaction.Payment

  @empty_metadata <<0::256>>
  @default_transactions_limit 200

  @type create_t() ::
          {:ok, nonempty_list(transaction_t())}
          | {:error, {:insufficient_funds, list(map())}}
          | {:error, :too_many_inputs}
          | {:error, :too_many_outputs}
          | {:error, :empty_transaction}

  @type order_t() :: %{
          owner: Crypto.address_t(),
          payments: nonempty_list(UtxoSelection.payment_t()),
          metadata: binary() | nil,
          fee: UtxoSelection.fee_t()
        }

  @type utxos_map_t() :: %{UtxoSelection.currency_t() => UtxoSelection.utxo_list_t()}
  @type inputs_t() :: {:ok, utxos_map_t()} | {:error, {:insufficient_funds, list(map())}} | {:error, :too_many_inputs}
  @type transaction_t() :: %{
          inputs: nonempty_list(%DB.TxOutput{}),
          outputs: nonempty_list(UtxoSelection.payment_t()),
          fee: UtxoSelection.fee_t(),
          txbytes: Transaction.tx_bytes() | nil,
          metadata: Transaction.metadata(),
          sign_hash: Crypto.hash_t() | nil,
          typed_data: TypedDataHash.Types.typedDataSignRequest_t()
        }

  @doc """
  Retrieves a specific transaction by id
  """
  @spec get(binary()) :: {:ok, %DB.Transaction{}} | {:error, :transaction_not_found}
  def get(transaction_id) do
    if transaction = DB.Transaction.get(transaction_id),
      do: {:ok, transaction},
      else: {:error, :transaction_not_found}
  end

  @doc """
  Retrieves a list of transactions that:
   - (optionally) a given address is involved as input or output owner.
   - (optionally) belong to a given child block number

  Length of the list is limited by `limit` argument
  """
  @spec get_transactions(Keyword.t()) :: Paginator.t(%DB.Transaction{})
  def get_transactions(constraints) do
    paginator = Paginator.from_constraints(constraints, @default_transactions_limit)

    constraints
    |> Keyword.drop([:limit, :page])
    |> DB.Transaction.get_by_filters(paginator)
  end

  @doc """
  Passes the signed transaction to the child chain.

  Caution: This function is unaware of the child chain's security status, e.g.:

  * Watcher is fully synced,
  * all operator blocks have been verified,
  * transaction doesn't spend funds not yet mined
  * etc...
  """
  @spec submit(Transaction.Signed.t()) :: Client.response_t() | {:error, atom()}
  def submit(%Transaction.Signed{} = signed_tx) do
    url = Application.get_env(:omg_watcher_info, :child_chain_url)

    signed_tx
    |> Transaction.Signed.encode()
    |> Client.submit(url)
  end

  @doc """
  Given order finds spender's inputs sufficient to perform a payment.
  If also provided with receiver's address, creates and encodes a transaction.
  """
  @spec create(order_t()) :: create_t()
  def create(order) do
    case(
      order.owner
      |> DB.TxOutput.get_sorted_grouped_utxos()
      |> select_inputs(order)
    ) do
      {:ok, inputs} ->
        TransactionCreator.create(inputs, order)

      err ->
        err
    end
  end

  @spec include_typed_data(UtxoSelection.advice_t()) :: UtxoSelection.advice_t()
  def include_typed_data({:error, _} = err), do: err

  def include_typed_data({:ok, txs}),
    do: {
      :ok,
      %{transactions: Enum.map(txs, fn tx -> Map.put_new(tx, :typed_data, add_type_specs(tx)) end)}
    }

  # Given an `order`, finds spender's inputs sufficient to perform a payment.
  # If also provided with receiver's address, creates and encodes a transaction.
  @spec select_inputs(utxos_map_t(), order_t()) :: inputs_t()
  defp select_inputs(utxos, %{payments: payments, fee: fee}) do
    token_utxo_selection =
      payments
      |> UtxoSelection.needed_funds(fee)
      |> UtxoSelection.select_utxo(utxos)

    case UtxoSelection.funds_sufficient(token_utxo_selection) do
      {:ok, funds} ->
        stealth_merge_utxos =
          utxos
          |> UtxoSelection.prioritize_merge_utxos(funds)
          |> UtxoSelection.add_utxos_for_stealth_merge(Map.new(funds))

        {:ok, stealth_merge_utxos}

      err ->
        err
    end
  end

  defp add_type_specs(%{inputs: inputs, outputs: outputs, metadata: metadata}) do
    message =
      [
        create_inputs(inputs),
        create_outputs(outputs),
        [metadata: metadata || @empty_metadata]
      ]
      |> Enum.concat()
      |> Map.new()

    %{
      domain: TypedDataHash.Config.domain_data_from_config(),
      message: message
    }
    |> Map.merge(TypedDataHash.Types.eip712_types_specification())
  end

  defp create_inputs(inputs) do
    inputs
    |> Stream.map(fn input -> %{blknum: input.blknum, txindex: input.txindex, oindex: input.oindex} end)
    |> Stream.concat(Stream.repeatedly(fn -> %{blknum: 0, txindex: 0, oindex: 0} end))
    |> (fn input -> Enum.zip([:input0, :input1, :input2, :input3], input) end).()
  end

  defp create_outputs(outputs) do
    zero_addr = OMG.Eth.zero_address()
    empty_gen = fn -> %{owner: zero_addr, currency: zero_addr, amount: 0} end

    outputs
    |> Stream.concat(Stream.repeatedly(empty_gen))
    |> (fn output -> Enum.zip([:output0, :output1, :output2, :output3], output) end).()
  end
end
