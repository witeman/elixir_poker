defmodule Poker.Table do
  use GenServer

  def start_link(num_seats) do
    GenServer.start_link(__MODULE__, num_seats)
  end

  def sit(table, seat) do
    GenServer.call(table, {:sit, seat})
  end

  def leave(table) do
    GenServer.call(table, :leave)
  end

  def buy_in(table, amount) do
    GenServer.call(table, {:buy_in, amount})
  end

  def cash_out(table) do
    GenServer.call(table, :cash_out)
  end

  def deal(table) do
    GenServer.call(table, :deal)
  end

  def update_balance(table, player, delta) do
    GenServer.call(table, {:update_balance, player, delta})
  end

  def players(table) do
    GenServer.call(table, :players)
  end

  ### GenServer callbacks
  def init(num_seats) do
    players = :ets.new(:players, [:protected])

    {:ok, %{hand: nil, players: players, num_seats: num_seats}}
  end

  def handle_call({:sit, seat}, _from, state = %{num_seats: last_seat}) when seat < 1 or seat > last_seat do
    {:reply, {:error, :seat_unavailable}, state}
  end

  def handle_call({:sit, seat}, {pid, _ref}, state) when is_integer(seat) do
    {:reply, seat_player(state, pid, seat), state}
  end

  def handle_call(:leave, {pid, _ref}, state = %{hand: nil}) do
    case get_player(state, pid) do
      {:ok, %{balance: 0}} ->
        unseat_player(state, pid)
        {:reply, :ok, state}
      {:ok, %{balance: balance}} when balance > 0 ->
        {:reply, {:error, :player_has_balance}, state}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:buy_in, amount}, {pid, _ref}, state = %{hand: nil}) when amount > 0 do
    case state |> get_player(pid) |> withdraw_funds(amount) do
      :ok ->
        modify_balance(state, pid, amount)
        {:reply, :ok, state}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:cash_out, {pid, _ref}, state = %{hand: nil}) do
    case clear_balance(state, pid) do
      {:ok, balance} ->
        Poker.Bank.deposit(pid, balance)
        {:reply, :ok, state}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:players, _from, state) do
    {:reply, get_players(state), state}
  end

  def handle_call(:deal, _from, state = %{hand: nil}) do
    players = get_players(state) |> Enum.map(&(&1.id))

    case Poker.Hand.start(self, players) do
      {:ok, hand} ->
        Process.monitor(hand)
        {:reply, {:ok, hand}, %{state | hand: hand}}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:deal, _from, state) do
    {:reply, {:error, :hand_in_progress}, state}
  end

  def handle_call({:update_balance, player, delta}, {hand, _ref}, state = %{hand: hand}) when delta >= 0 do
    case get_player(state, player) do
      {:ok, _} ->
        modify_balance(state, player, delta)
        {:reply, :ok, state}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:update_balance, player, delta}, {hand, _ref}, state = %{hand: hand}) when delta < 0 do
    case get_player(state, player) do
      {:ok, %{balance: balance}} when balance + delta >= 0 ->
        modify_balance(state, player, delta)
        {:reply, :ok, state}
      {:ok, _} ->
        {:reply, {:error, :insufficient_funds}, state}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:update_balance, _, _}, _, state) do
    {:reply, {:error, :invalid_hand}, state}
  end

  def handle_info({:DOWN, _ref, _type, hand, _reason}, state = %{hand: hand}) do
    {:noreply, %{state | hand: nil}}
  end

  defp withdraw_funds({:ok, %{id: pid}}, amount), do: Poker.Bank.withdraw(pid, amount)
  defp withdraw_funds(error, _amount), do: error

  defp seat_player(%{players: players}, player, seat) do
    case :ets.match_object(players, {:_, seat, :_}) do
      [] ->
        :ets.insert(players, {player, seat, 0})
        :ok
      _ -> {:error, :seat_taken}
    end
  end

  defp unseat_player(state, player) do
    :ets.delete(state.players, player)
  end

  defp modify_balance(state, player, delta) do
    :ets.update_counter(state.players, player, {3, delta})
  end

  defp clear_balance(state, player) do
    case get_player(state, player) do
      {:ok, %{balance: balance}} ->
        :ets.update_element(state.players, player, {3, 0})
        {:ok, balance}
      error ->
        error
    end
  end

  defp get_players(state) do
    :ets.tab2list(state.players) |>
      Enum.sort_by(fn {_, seat, _} -> seat end) |>
      Enum.map(&player_to_map/1)
  end

  defp get_player(state, player) do
    case :ets.lookup(state.players, player) do
      [] -> {:error, :not_at_table}
      [tuple] -> {:ok, player_to_map(tuple)}
    end
  end

  defp player_to_map({id, seat, balance}), do: %{id: id, seat: seat, balance: balance}
end