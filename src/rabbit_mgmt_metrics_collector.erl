%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%
-module(rabbit_mgmt_metrics_collector).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(gen_server2).

-spec start_link(atom()) -> rabbit_types:ok_pid_or_error().

-export([name/1]).
-export([start_link/1]).
-export([override_lookups/2, reset_lookups/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-import(rabbit_misc, [pget/3]).
-import(rabbit_mgmt_db, [pget/2, lookup_element/3]).

-record(state, {table, agent, policies, rates_mode, lookup_queue, lookup_exchange}).

name(Table) ->
    list_to_atom((atom_to_list(Table) ++ "_metrics_collector")).

start_link(Table) ->
    gen_server2:start_link({local, name(Table)}, ?MODULE, [Table], []).

override_lookups(Table, Lookups) ->
    gen_server2:call(name(Table), {override_lookups, Lookups}, infinity).

reset_lookups(Table) ->
    gen_server2:call(name(Table), reset_lookups, infinity).

init([Table]) ->    
    {ok, RatesMode} = application:get_env(rabbitmq_management, rates_mode),
    {ok, Policies} = application:get_env(
                       rabbitmq_management, sample_retention_policies),
    Policy = retention_policy(Table),
    Interval = take_smaller(proplists:get_value(Policy, Policies)),
    {ok, Agent} = rabbit_mgmt_agent_collector_sup:start_child(self(), Table,
							      Interval * 1000),
    {ok, #state{table = Table, agent = Agent,
		policies = {proplists:get_value(basic, Policies),
			    proplists:get_value(detailed, Policies),
			    proplists:get_value(global, Policies)},
		rates_mode = RatesMode,
		lookup_queue = fun queue_exists/1,
		lookup_exchange = fun exchange_exists/1}}.

handle_call(reset_lookups, _From, State) ->
    {reply, ok, State#state{lookup_queue = fun queue_exists/1,
			    lookup_exchange = fun exchange_exists/1}};
handle_call({override_lookups, Lookups}, _From, State) ->
    {reply, ok, State#state{lookup_queue = pget(queue, Lookups),
			    lookup_exchange = pget(exchange, Lookups)}};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({metrics, Timestamp, Records}, State) ->
    aggregate_metrics(Timestamp, Records, State),
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

retention_policy(connection_created) -> basic; %% really nothing
retention_policy(connection_metrics) -> basic;
retention_policy(connection_coarse_metrics) -> basic;
retention_policy(channel_created) -> basic;
retention_policy(channel_metrics) -> basic;
retention_policy(channel_queue_exchange_metrics) -> detailed;
retention_policy(channel_exchange_metrics) -> detailed;
retention_policy(channel_queue_metrics) -> detailed;
retention_policy(channel_process_metrics) -> basic;
retention_policy(consumer_created) -> basic;
retention_policy(queue_metrics) -> basic; 
retention_policy(queue_coarse_metrics) -> basic;
retention_policy(node_persister_metrics) -> global;
retention_policy(node_coarse_metrics) -> global;
retention_policy(node_metrics) -> basic;
retention_policy(node_node_metrics) -> global.

take_smaller(Policies) ->
    lists:min([I || {_, I} <- Policies]).

aggregate_metrics(Timestamp, Records, State) ->
    [aggregate_entry(Timestamp, R, State) || R <- Records].

aggregate_entry(_TS, {Id, Metrics}, #state{table = connection_created}) ->
    Ftd = rabbit_mgmt_format:format(
	    Metrics,
	    {fun rabbit_mgmt_format:format_connection_created/1, true}),
    ets:insert(connection_created_stats, {Id, pget(name, Ftd, unknown), Ftd});
aggregate_entry(_TS, {Id, Metrics}, #state{table = connection_metrics}) ->
    ets:insert(connection_stats, {Id, Metrics});
aggregate_entry(TS, {Id, RecvOct, SendOct, Reductions},
		#state{table = connection_coarse_metrics,
		       policies = {BPolicies, _, GPolicies}}) ->
    Stats = {RecvOct, SendOct},
    Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, {Id, Stats}),
    [insert_entry(vhost_stats_coarse_conn_stats, vhost({connection_created_stats, Id}),
		 TS, Diff, Size, Interval, true) || {Size, Interval} <- GPolicies],
    [begin
         insert_entry(connection_stats_coarse_conn_stats, Id, TS,
                      {RecvOct, SendOct, Reductions}, Size, Interval, false)
     end || {Size, Interval} <- BPolicies];
aggregate_entry(_TS, {Id, Metrics}, #state{table = channel_created}) ->
    Ftd = rabbit_mgmt_format:format(Metrics, {[], false}),
    ets:insert(channel_created_stats, {Id, pget(name, Ftd, unknown), Ftd});
aggregate_entry(_TS, {Id, Metrics}, #state{table = channel_metrics}) ->
    Ftd = rabbit_mgmt_format:format(Metrics,
				    {fun rabbit_mgmt_format:format_channel_stats/1, true}),
    ets:insert(channel_stats, {Id, Ftd});
aggregate_entry(TS, {{Ch, X} = Id, Metrics}, #state{table = channel_exchange_metrics,
						    policies = {_, DPolicies, _},
						    rates_mode = RatesMode,
						    lookup_exchange = ExchangeFun}) ->
    Stats = {pget(publish, Metrics, 0), pget(confirm, Metrics, 0),
	     pget(return_unroutable, Metrics, 0)},
    {Publish, _, _} = Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, {Id, Stats}),
    [begin
         insert_entry(channel_stats_fine_stats, Ch, TS, Diff, Size, Interval,
		      true),
         insert_entry(vhost_stats_fine_stats, vhost(X), TS, Diff, Size,
		      Interval, true)
     end || {Size, Interval} <- DPolicies],
    case {ExchangeFun(X), RatesMode} of
	{true, basic} ->
	    [insert_entry(exchange_stats_publish_in, X, TS, {Publish}, Size, Interval,
			  true) || {Size, Interval} <- DPolicies];
	{true, _} ->
	    [begin
		 insert_entry(exchange_stats_publish_in, X, TS, {Publish}, Size, Interval,
			      true),
		 insert_entry(channel_exchange_stats_fine_stats, Id, TS, Stats,
			      Size, Interval, false)
	     end || {Size, Interval} <- DPolicies];
	_ ->
	    ok
    end;
aggregate_entry(TS, {{Ch, Q} = Id, Metrics}, #state{table = channel_queue_metrics,
						    policies = {_, DPolicies, _},
						    rates_mode = RatesMode,
						    lookup_queue = QueueFun}) ->
    Deliver = pget(deliver, Metrics, 0),
    DeliverNoAck = pget(deliver_no_ack, Metrics, 0),
    Get = pget(get, Metrics, 0),
    GetNoAck = pget(get_no_ack, Metrics, 0),
    Stats = {Get, GetNoAck, Deliver, DeliverNoAck, pget(redeliver, Metrics, 0),
	     pget(ack, Metrics, 0), Deliver + DeliverNoAck + Get + GetNoAck},
    Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, {Id, Stats}),
    [begin
	 insert_entry(vhost_stats_deliver_stats, vhost(Q), TS, Diff, Size,
		      Interval, true),
	 insert_entry(channel_stats_deliver_stats, Ch, TS, Diff, Size, Interval,
		      true)
     end || {Size, Interval} <- DPolicies],
    case {QueueFun(Q), RatesMode} of
	{true, basic} ->
	    [insert_entry(queue_stats_deliver_stats, Q, TS, Diff, Size, Interval,
			  true) || {Size, Interval} <- DPolicies];
	{true, _} ->
	    [begin
		 insert_entry(queue_stats_deliver_stats, Q, TS, Diff, Size, Interval,
			      true),
		 insert_entry(channel_queue_stats_deliver_stats, Id, TS, Stats, Size,
			       Interval, false)
	     end || {Size, Interval} <- DPolicies];
	_ ->
	    ok
    end;
aggregate_entry(TS, {{_Ch, {Q, X} = Id}, Publish}, #state{table = channel_queue_exchange_metrics,
							  policies = {_, DPolicies, _},
							  rates_mode = RatesMode,
							  lookup_queue = QueueFun,
							  lookup_exchange = ExchangeFun}) ->
    Stats = {Publish},
    Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, {Id, Stats}),
    case {QueueFun(Q), ExchangeFun(Q), RatesMode} of
	{true, false, _} ->
	    [insert_entry(queue_stats_publish, Q, TS, Diff, Size, Interval, true)
	     || {Size, Interval} <- DPolicies];
	{false, true, _} ->
	    [insert_entry(exchange_stats_publish_out, X, TS, Diff, Size, Interval, true)
	     || {Size, Interval} <- DPolicies];
	{true, true, basic} ->
	    [begin
		 insert_entry(queue_stats_publish, Q, TS, Diff, Size, Interval, true),
		 insert_entry(exchange_stats_publish_out, X, TS, Diff, Size, Interval, true)
	     end || {Size, Interval} <- DPolicies];
	{true, true, _} ->
	    [begin
		 insert_entry(queue_stats_publish, Q, TS, Diff, Size, Interval, true),
		 insert_entry(exchange_stats_publish_out, X, TS, Diff, Size, Interval, true),
		 insert_entry(queue_exchange_stats_publish, Id, TS, Diff, Size, Interval, true)
	     end || {Size, Interval} <- DPolicies];
	_ ->
	    ok
    end;
aggregate_entry(TS, {Id, Reductions}, #state{table = channel_process_metrics,
					     policies = {BPolicies, _, _}}) ->
    [begin
	 insert_entry(channel_process_stats, Id, TS, {Reductions}, Size, Interval,
		      false)
     end || {Size, Interval} <- BPolicies];
aggregate_entry(_TS, {Id, Exclusive, AckRequired, PrefetchCount, Args},
		#state{table = consumer_created}) ->
    Fmt = rabbit_mgmt_format:format([{exclusive, Exclusive},
				     {ack_required, AckRequired},
				     {prefetch_count, PrefetchCount},
				     {arguments, Args}], {[], false}),
    ets:insert(consumer_stats, {Id, Fmt}),
    ok;
aggregate_entry(TS, {Id, Metrics}, #state{table = queue_metrics,
					  policies = {BPolicies, _, GPolicies},
					  lookup_queue = QueueFun}) ->
    Stats = {pget(disk_reads, Metrics, 0), pget(disk_writes, Metrics, 0)},
    Diff = get_difference({Id, rates}, Stats),
    ets:insert(old_aggr_stats, {{Id, rates}, Stats}),
    [insert_entry(vhost_msg_rates, Id, TS, Diff, Size, Interval, true)
     || {Size, Interval} <- GPolicies],
    case QueueFun(Id) of
	true ->
	    [insert_entry(queue_msg_rates, Id, TS, Stats, Size, Interval, false)
	     || {Size, Interval} <- BPolicies],
	    Fmt = rabbit_mgmt_format:format(
		    Metrics,
		    {fun rabbit_mgmt_format:format_queue_stats/1, false}),
	    ets:insert(queue_stats, {Id, Fmt});
	false ->
	    ok
    end;
aggregate_entry(TS, {Name, Ready, Unack, Msgs, Red}, #state{table = queue_coarse_metrics,
							    policies = {BPolicies, _, GPolicies},
							    lookup_queue = QueueFun}) ->
    Stats = {Ready, Unack, Msgs},
    Diff = get_difference(Name, Stats),
    ets:insert(old_aggr_stats, {Name, Stats}),
    [insert_entry(vhost_msg_stats, vhost(Name), TS, Diff, Size, Interval, true)
     || {Size, Interval} <- GPolicies],
    case QueueFun(Name) of
	true ->
	    [begin
		 insert_entry(queue_process_stats, Name, TS, {Red},
			      Size, Interval, false),
		 insert_entry(queue_msg_stats, Name, TS, {Ready, Unack, Msgs},
		      Size, Interval, false)
	     end || {Size, Interval} <- BPolicies];
	_ ->
	    ok
    end;
aggregate_entry(_TS, {Id, Metrics}, #state{table = node_metrics}) ->
    ets:insert(node_stats, {Id, Metrics});
aggregate_entry(TS, {Id, Metrics}, #state{table = node_coarse_metrics,
					  policies = {_, _, GPolicies}}) ->
    Stats = {pget(fd_used, Metrics, 0), pget(sockets_used, Metrics, 0),
	     pget(mem_used, Metrics, 0), pget(disk_free, Metrics, 0),
	     pget(proc_used, Metrics, 0), pget(gc_num, Metrics, 0),
	     pget(gc_bytes_reclaimed, Metrics, 0), pget(context_switches, Metrics, 0)},
    [insert_entry(node_coarse_stats, Id, TS, Stats, Size, Interval, false)
     || {Size, Interval} <- GPolicies];
aggregate_entry(TS, {Id, Metrics}, #state{table = node_persister_metrics,
					  policies = {_, _, GPolicies}}) ->
    Stats = {pget(io_read_count, Metrics, 0), pget(io_read_bytes, Metrics, 0),
	     pget(io_read_time, Metrics, 0), pget(io_write_count, Metrics, 0),
	     pget(io_write_bytes, Metrics, 0), pget(io_write_time, Metrics, 0),
	     pget(io_sync_count, Metrics, 0), pget(io_sync_time, Metrics, 0),
	     pget(io_seek_count, Metrics, 0), pget(io_seek_time, Metrics, 0),
	     pget(io_reopen_count, Metrics, 0), pget(mnesia_ram_tx_count, Metrics, 0),
	     pget(mnesia_disk_tx_count, Metrics, 0), pget(msg_store_read_count, Metrics, 0),
	     pget(msg_store_write_count, Metrics, 0),
	     pget(queue_index_journal_write_count, Metrics, 0),
	     pget(queue_index_write_count, Metrics, 0), pget(queue_index_read_count, Metrics, 0),
	     pget(io_file_handle_open_attempt_count, Metrics, 0),
	     pget(io_file_handle_open_attempt_time, Metrics, 0)},
    [insert_entry(node_persister_stats, Id, TS, Stats, Size, Interval, false)
     || {Size, Interval} <- GPolicies];
aggregate_entry(TS, {Id, Metrics}, #state{table = node_node_metrics,
					  policies = {_, _, GPolicies}}) ->
    Stats = {pget(send_bytes, Metrics, 0), pget(recv_bytes, Metrics, 0)},
    CleanMetrics = lists:keydelete(recv_bytes, 1, lists:keydelete(send_bytes, 1, Metrics)),
    ets:insert(node_node_stats, {Id, CleanMetrics}),
    [insert_entry(node_node_coarse_stats, Id, TS, Stats, Size, Interval, false)
     || {Size, Interval} <- GPolicies].

insert_entry(Table, Id, TS, Entry, Size, Interval, Incremental) ->
    Key = {Id, Interval},
    Slide = case ets:lookup(Table, Key) of
                [{Key, S}] ->
                    S;
                [] ->
                    exometer_slide:new(Size * 1000, [{interval, Interval * 1000},
						     {incremental, Incremental}])
            end,
    ets:insert(Table, {Key, exometer_slide:add_element(TS, Entry, Slide)}).

get_difference(Id, Stats) ->
    case ets:lookup(old_aggr_stats, Id) of
	[] ->
	    Stats;
	[{Id, OldStats}] ->
	    difference(OldStats, Stats)
    end.

difference({A0}, {B0}) ->
    {B0 - A0};
difference({A0, A1}, {B0, B1}) ->
    {B0 - A0, B1 - A1};
difference({A0, A1, A2}, {B0, B1, B2}) ->
    {B0 - A0, B1 - A1, B2 - A2};
difference({A0, A1, A2, A3, A4, A5, A6}, {B0, B1, B2, B3, B4, B5, B6}) ->
    {B0 - A0, B1 - A1, B2 - A2, B3 - A3, B4 - A4, B5 - A5, B6 - A6}.

vhost(#resource{virtual_host = VHost}) ->
    VHost;
vhost({queue_stats, #resource{virtual_host = VHost}}) ->
    VHost;
vhost({TName, Pid}) ->
    pget(vhost, lookup_element(TName, Pid, 3)).

exchange_exists(Name) ->
    case rabbit_exchange:lookup(Name) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.

queue_exists(Name) ->
    case rabbit_amqqueue:lookup(Name) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.