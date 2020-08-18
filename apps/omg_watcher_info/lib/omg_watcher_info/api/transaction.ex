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

  alias OMG.State.Transaction
  alias OMG.Utils.Paginator
  alias OMG.Utxo
  alias OMG.WatcherInfo.DB
  alias OMG.WatcherInfo.HttpRPC.Client
  alias OMG.WatcherInfo.UtxoSelection
  alias OMG.TypedDataHash

  require Utxo
  require Transaction.Payment

  @default_transactions_limit 200
  @empty_metadata <<0::256>>

  @type create_t() ::
          {:ok,
           %{
             result: :complete | :intermediate,
             transactions: nonempty_list(UtxoSelection.transaction_t())
           }}
          | {:error, {:insufficient_funds, list(map())}}
          | {:error, :too_many_inputs}
          | {:error, :too_many_outputs}
          | {:error, :empty_transaction}

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
  @spec create(UtxoSelection.order_t()) :: create_t()
  def create(order) do
    case order.owner
         |> DB.TxOutput.get_sorted_grouped_utxos()
         |> UtxoSelection.create_advice(order) do
      {:error, reason} ->
        {:error, reason}

      result ->
        result
        |> create_transaction(order)
        |> respond(:complete)
    end

    # IO.inspect(result)
  end

  @spec include_typed_data(UtxoSelection.advice_t()) :: UtxoSelection.advice_t()
  def include_typed_data({:error, _} = err), do: err

  def include_typed_data({:ok, %{transactions: txs} = advice}),
    do: {
      :ok,
      %{advice | transactions: Enum.map(txs, fn tx -> Map.put_new(tx, :typed_data, add_type_specs(tx)) end)}
    }

  defp add_type_specs(%{inputs: inputs, outputs: outputs, metadata: metadata}) do
    alias OMG.TypedDataHash

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
    empty_gen = fn -> %{blknum: 0, txindex: 0, oindex: 0} end

    inputs
    |> Stream.map(&Map.take(&1, [:blknum, :txindex, :oindex]))
    |> Stream.concat(Stream.repeatedly(empty_gen))
    |> (&Enum.zip([:input0, :input1, :input2, :input3], &1)).()
  end

  defp create_outputs(outputs) do
    zero_addr = OMG.Eth.zero_address()
    empty_gen = fn -> %{owner: zero_addr, currency: zero_addr, amount: 0} end

    outputs
    |> Stream.concat(Stream.repeatedly(empty_gen))
    |> (&Enum.zip([:output0, :output1, :output2, :output3], &1)).()
  end

  defp create_transaction(utxos_per_token, %{
         owner: owner,
         payments: payments,
         metadata: metadata,
         fee: fee
       }) do
    rests =
      utxos_per_token
      |> Stream.map(fn {token, utxos} ->
        outputs =
          [fee | payments]
          |> Stream.filter(&(&1.currency == token))
          |> Stream.map(& &1.amount)
          |> Enum.sum()

        inputs = utxos |> Stream.map(& &1.amount) |> Enum.sum()
        %{amount: inputs - outputs, owner: owner, currency: token}
      end)
      |> Enum.filter(&(&1.amount > 0))

    outputs = payments ++ rests

    inputs =
      utxos_per_token
      |> Enum.map(fn {_, utxos} -> utxos end)
      |> List.flatten()

    cond do
      Enum.count(outputs) > Transaction.Payment.max_outputs() ->
        {:error, :too_many_outputs}

      Enum.empty?(inputs) ->
        {:error, :empty_transaction}

      true ->
        raw_tx = create_raw_transaction(inputs, outputs, metadata)

        {:ok,
         %{
           inputs: inputs,
           outputs: outputs,
           fee: fee,
           metadata: metadata,
           txbytes: create_txbytes(raw_tx),
           sign_hash: compute_sign_hash(raw_tx)
         }}
    end
  end

  defp create_raw_transaction(inputs, outputs, metadata) do
    if Enum.any?(outputs, &(&1.owner == nil)),
      do: nil,
      else:
        Transaction.Payment.new(
          inputs |> Enum.map(&{&1.blknum, &1.txindex, &1.oindex}),
          outputs |> Enum.map(&{&1.owner, &1.currency, &1.amount}),
          metadata || @empty_metadata
        )
  end

  defp create_txbytes(tx) do
    with tx when not is_nil(tx) <- tx,
         do: Transaction.raw_txbytes(tx)
  end

  defp compute_sign_hash(tx) do
    with tx when not is_nil(tx) <- tx,
         do: TypedDataHash.hash_struct(tx)
  end

  defp respond({:ok, transaction}, result),
    do: {:ok, %{result: result, transactions: [transaction]}}

  defp respond(transactions, result) when is_list(transactions),
    do: {:ok, %{result: result, transactions: transactions}}

  defp respond(error, _), do: error
end
