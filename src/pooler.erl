%% @author Seth Falcon <seth@userprimary.net>
%% @copyright 2011-2012 Seth Falcon
%% @doc This is the main interface to the pooler application
%%
%% To integrate with your application, you probably want to call
%% application:start(pooler) after having specified appropriate
%% configuration for the pooler application (either via a config file
%% or appropriate calls to the application module to set the
%% application's config).
%%
-module(pooler).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(DEFAULT_ADD_RETRY, 1).
-define(DEFAULT_CULL_INTERVAL, {0, min}).
-define(DEFAULT_MAX_AGE, {0, min}).

-include_lib("eunit/include/eunit.hrl").

-type member_info() :: {string(), free | pid(), {_, _, _}}.
-type free_member_info() :: {string(), free, {_, _, _}}.
-type time_unit() :: min | sec | ms | mu.
-type time_spec() :: {non_neg_integer(), time_unit()}.

%% type specs for pool metrics
-type metric_label() :: binary().
-type metric_value() :: 'unknown_pid' |
                        non_neg_integer() |
                        {'add_pids_failed', non_neg_integer(), non_neg_integer()} |
                        {'inc',1} |
                        'error_no_members'.
-type metric_type() :: 'counter' | 'histogram' | 'history' | 'meter'.

-record(pool, {
          name             :: string(),
          max_count = 100  :: non_neg_integer(),
          init_count = 10  :: non_neg_integer(),
          start_mfa        :: {atom(), atom(), [term()]},
          free_pids = []   :: [pid()],
          in_use_count = 0 :: non_neg_integer(),
          free_count = 0   :: non_neg_integer(),
          %% The number times to attempt adding a pool member if the
          %% pool size is below max_count and there are no free
          %% members. After this many tries, error_no_members will be
          %% returned by a call to take_member. NOTE: this value
          %% should be >= 2 or else the pool will not grow on demand
          %% when max_count is larger than init_count.
          add_member_retry = ?DEFAULT_ADD_RETRY :: non_neg_integer(),

          %% The interval to schedule a cull message. Both
          %% 'cull_interval' and 'max_age' are specified using a
          %% `time_spec()' type.
          cull_interval = ?DEFAULT_CULL_INTERVAL :: time_spec(),
          %% The maximum age for members.
          max_age = ?DEFAULT_MAX_AGE             :: time_spec()
         }).

-record(state, {
          npools = 0                   :: non_neg_integer(),
          pools = dict:new()           :: dict(),
          pool_sups = dict:new()       :: dict(),
          all_members = dict:new()     :: dict(),
          consumer_to_pid = dict:new() :: dict(),
          pool_selector = array:new()  :: array()
         }).

-define(gv(X, Y), proplists:get_value(X, Y)).
-define(gv(X, Y, D), proplists:get_value(X, Y, D)).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start/1,
         start_link/1,
         stop/0,
         addpool/1,
         addpools/1,
         take_member/0,
         take_member/1,
         return_member/1,
         return_member/2,
         % remove_pool/2,
         % add_pool/1,
         pool_stats/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% To help with testing internal functions
-ifdef(TEST).
-compile([export_all]).
-endif.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Config, []).

start(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Config, []).

stop() ->
    gen_server:call(?SERVER, stop).

%% @doc Add a new pool.
%% PoolConfig is a proplist, same as what is passed to start.
%% Returns ok|{error, ErrorInfo}
-spec addpool([atom()|{atom(), term()}]) -> ok | {error, term()}.
addpool(PoolConfig) ->
    gen_server:call(?SERVER, {addpool, PoolConfig}).

%% @doc Add multiple pools.
%% Input is a list of PoolConfigs.
%% Returns ok|{error, ErrorInfo}
-spec addpools([[atom()|{atom(), term()}]]) -> ok | {error, term()}.
addpools(PoolConfigs) ->
    gen_server:call(?SERVER, {addpools, PoolConfigs}).

%% @doc Obtain exclusive access to a member from a randomly selected pool.
%%
%% If there are no free members in the randomly selected pool, then a
%% member will be returned from the pool with the most free members.
%% If no free members are available, 'error_no_members' is returned.
%%
-spec take_member() -> pid() | error_no_members.
take_member() ->
    gen_server:call(?SERVER, take_member).

%% @doc Obtain exclusive access to a member from `PoolName'.
%%
%% If no free members are available, 'error_no_members' is returned.
%%
-spec take_member(string()) -> pid() | error_no_members | error_no_pool.
take_member(PoolName) when is_list(PoolName) ->
    gen_server:call(?SERVER, {take_member, PoolName}).

%% @doc Return a member to the pool so it can be reused.
%%
%% If `Status' is 'ok', the member is returned to the pool.  If
%% `Status' is 'fail', the member is destroyed and a new member is
%% added to the pool in its place.
-spec return_member(pid() | error_no_members, ok | fail) -> ok.
return_member(Pid, Status) when is_pid(Pid) andalso
                                (Status =:= ok orelse Status =:= fail) ->
    CPid = self(),
    gen_server:cast(?SERVER, {return_member, Pid, Status, CPid}),
    ok;
return_member(error_no_members, _) ->
    ok.

%% @doc Return a member to the pool so it can be reused.
%%
-spec return_member(pid() | error_no_members) -> ok.
return_member(Pid) when is_pid(Pid) ->
    CPid = self(),
    gen_server:cast(?SERVER, {return_member, Pid, ok, CPid}),
    ok;
return_member(error_no_members) ->
    ok.

% TODO:
% remove_pool(Name, How) when How == graceful; How == immediate ->
%     gen_server:call(?SERVER, {remove_pool, Name, How}).

%% @doc Obtain runtime state info for all pools.
%%
%% Format of the return value is subject to change.
-spec pool_stats() -> [tuple()].
pool_stats() ->
    gen_server:call(?SERVER, pool_stats).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init([any()]) -> {'ok', #state{npools::'undefined' | non_neg_integer(),
                                     pools::dict(),
                                     pool_sups::dict(),
                                     all_members::dict(),
                                     consumer_to_pid::dict(),
                                     pool_selector::'undefined' | array()}}.
init(Config) ->
    process_flag(trap_exit, true),
    State0 = #state{},
    try
        State1 = addpools(?gv(pools, Config), State0),
        {ok, State1}
    catch
        throw:duplicate_pool_name -> {error, duplicate_pool_name}
    end.

handle_call({addpool, PoolConfig}, {_CPid, _Tag}, State) ->
    try
        State1 = addpool(PoolConfig, State),
        {reply, ok, State1}
    catch
        throw:duplicate_pool_name ->
            {reply, {error, duplicate_pool_name}, State}
    end;
handle_call({addpools, PoolConfigs}, {_CPid, _Tag}, State) ->
    State1 = addpools(PoolConfigs, State),
    {reply, ok, State1};
handle_call(take_member, {CPid, _Tag}, State) ->
    {Result, NewState} =  pick_member(CPid, State),
    {reply, Result, NewState};
handle_call({take_member, PoolName}, {CPid, _Tag}, #state{} = State) ->
    {Member, NewState} = take_member(PoolName, CPid, State),
    {reply, Member, NewState};
handle_call(stop, _From, State) ->
    {stop, normal, stop_ok, State};
handle_call(pool_stats, _From, State) ->
    {reply, dict:to_list(State#state.all_members), State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

-spec handle_cast(_,_) -> {'noreply', _}.
handle_cast({return_member, Pid, Status, _CPid}, State) ->
    {noreply, do_return_member(Pid, Status, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(_, _) -> {'noreply', _}.
handle_info({'EXIT', Pid, Reason}, State) ->
    State1 =
        case dict:find(Pid, State#state.all_members) of
            {ok, {_PoolName, _ConsumerPid, _Time}} ->
                do_return_member(Pid, fail, State);
            error ->
                case dict:find(Pid, State#state.consumer_to_pid) of
                    {ok, Pids} ->
                        IsOk = case Reason of
                                   normal -> ok;
                                   _Crash -> fail
                               end,
                        lists:foldl(
                          fun(P, S) -> do_return_member(P, IsOk, S) end,
                          State, Pids);
                    error ->
                        State
                end
        end,
    {noreply, State1};
handle_info({cull_pool, PoolName}, State) ->
    {noreply, cull_members(PoolName, State)};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(_, _) -> 'ok'.
terminate(_Reason, _State) ->
    ok.

-spec code_change(_, _, _) -> {'ok', _}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% @doc Internal version of addpools.
%% Iterate over list of pool specifications calling addpool/2.
-spec addpools([[atom()|{atom(), term()}]], #state{}) -> #state{}.
addpools(PoolConfigs, State) ->
    lists:foldl(fun addpool/2, State, PoolConfigs).

%% @doc Internal version of addpool.
%% Input is a proplist representing pool specifications, plus
%% state.
%% Updates state, starts pool supervisors, workers, etc.
%% Returns updated state.
-spec addpool([atom()|{atom(), term()}], #state{}) -> #state{}.
addpool(PoolConfig, #state{npools = NPools,
                           pools = Pools,
                           pool_sups = PoolSups,
                           pool_selector = PoolSelector} = State) ->
    PoolRec = props_to_pool(PoolConfig),
    %% Make sure we don't have a pool under that name already
    case fetch_pool(PoolRec#pool.name, Pools) of
        error_no_pool -> ok;
        _Pool -> throw(duplicate_pool_name)
    end,
    OutPools = dict:store(PoolRec#pool.name, PoolRec, Pools),
    {ok, SupPid} = supervisor:start_child(pooler_pool_sup, [PoolRec#pool.start_mfa]),
    OutPoolSups = dict:store(PoolRec#pool.name, SupPid, PoolSups),
    OutPoolSelector = array:set(array:size(PoolSelector), PoolRec#pool.name, PoolSelector),
    State1 = State#state{npools = NPools + 1,
                           pools = OutPools,
                           pool_sups = OutPoolSups,
                           pool_selector = OutPoolSelector},
    State2 = cull_members(PoolRec#pool.name, State1), % schedules culling
    {ok, State3} = add_pids(PoolRec#pool.name, PoolRec#pool.init_count, State2),
    State3.

-spec props_to_pool([{atom(), term()}]) -> #pool{}.
props_to_pool(P) ->
    #pool{      name = ?gv(name, P),
           max_count = ?gv(max_count, P),
          init_count = ?gv(init_count, P),
           start_mfa = ?gv(start_mfa, P),
    add_member_retry = ?gv(add_member_retry, P, ?DEFAULT_ADD_RETRY),
       cull_interval = ?gv(cull_interval, P, ?DEFAULT_CULL_INTERVAL),
             max_age = ?gv(max_age, P, ?DEFAULT_MAX_AGE)}.

% FIXME: creation of new pids should probably happen
% in a spawned process to avoid tying up the loop.
-spec add_pids(error | string(), non_neg_integer(), #state{}) ->
    {bad_pool_name | max_count_reached | ok, #state{}}.
add_pids(error, _N, State) ->
    {bad_pool_name, State};
add_pids(PoolName, N, State) ->
    #state{pools = Pools, all_members = AllMembers} = State,
    Pool = fetch_pool(PoolName, Pools),
    #pool{max_count = Max, free_pids = Free,
          in_use_count = NumInUse, free_count = NumFree} = Pool,
    Total = NumFree + NumInUse,
    case Total + N =< Max of
        true ->
            PoolSup = dict:fetch(PoolName, State#state.pool_sups),
            {AllMembers1, NewPids} = start_n_pids(N, PoolName, PoolSup,
                                                  AllMembers),
            %% start_n_pids may return fewer than N if errors were
            %% encountered.
            NewPidCount = length(NewPids),
            case NewPidCount =:= N of
                true -> ok;
                false ->
                    error_logger:error_msg("tried to add ~B members, only added ~B~n",
                                           [N, NewPidCount]),
                    send_metric(<<"pooler.events">>,
                                {add_pids_failed, N, NewPidCount}, history)
            end,
            Pool1 = Pool#pool{free_pids = Free ++ NewPids,
                              free_count = length(Free) + NewPidCount},
            {ok, State#state{pools = store_pool(PoolName, Pool1, Pools),
                             all_members = AllMembers1}};
        false ->
            {max_count_reached, State}
    end.

-define(PICK_STRATEGIES, [random, free, available]).

%% @doc Pick a pool member and check it out.
%% Tries several strategies to pick the pool:
%%
%% 1. random
%% 2. max free members
%% 3. max available members
%%
%% Returns {Result, NewState}.
%% Result is pid of pool member checked out, or
%% error_no_pool, or error_no_members.
%%
-spec pick_member(pid(), #state{}) ->
    {error_no_pool | error_no_members | pid(), #state{}}.
pick_member(From, State) ->
    pick_member(From, State, ?PICK_STRATEGIES).

pick_member(_From, State, []) ->
    {error_no_members, State};
pick_member(From, State, [Strategy|Strategies]) ->
    case pick_pool(State, Strategy) of
        error_no_members ->
            pick_member(From, State, Strategies);
        PoolName ->
            case take_member(PoolName, From, State) of
                {error_no_members, NewState} ->
                    pick_member(From, NewState, Strategies);
                Other ->
                    Other
            end
    end.

%% @doc Pick a pool according to given strategy
%% Returns a pool name or error_no_members or error_no_pool.
-spec pick_pool(#state{}, random|free|available) ->
          error_no_member|error_no_pools|string().
pick_pool(#state{pools=[]}=_State, _Strategy) ->
    error_no_pool;
pick_pool(#state{pool_selector = PS, npools = NP}=_State, random) ->
    array:get(crypto:rand_uniform(0, NP), PS);
pick_pool(#state{pools=Pools}=_State, free) ->
    max_free_pool(Pools);
pick_pool(#state{pools=Pools}=_State, available) ->
    max_avail_pool(Pools).

-spec take_member(string(), {pid(), _}, #state{}) ->
    {error_no_pool | error_no_members | pid(), #state{}}.
take_member(PoolName, From, #state{pools = Pools} = State) ->
    Pool = fetch_pool(PoolName, Pools),
    take_member_from_pool(Pool, From, State, pool_add_retries(Pool)).

-spec take_member_from_pool(error_no_pool | #pool{}, {pid(), term()}, #state{},
                            non_neg_integer()) ->
                                   {error_no_pool | error_no_members | pid(), #state{}}.
take_member_from_pool(error_no_pool, _From, State, _) ->
    {error_no_pool, State};
take_member_from_pool(#pool{name = PoolName,
                            max_count = Max,
                            free_pids = Free,
                            in_use_count = NumInUse,
                            free_count = NumFree} = Pool,
                      From,
                      #state{pools = Pools, consumer_to_pid = CPMap} = State,
                      Retries) ->
    send_metric(pool_metric(PoolName, take_rate), 1, meter),
    case Free of
        [] when NumInUse =:= Max ->
            send_metric(<<"pooler.error_no_members_count">>, {inc, 1}, counter),
            send_metric(<<"pooler.events">>, error_no_members, history),
            {error_no_members, State};
        [] when NumInUse < Max andalso Retries > 0 ->
            case add_pids(PoolName, 1, State) of
                {ok, State1} ->
                    %% add_pids may have updated our pool
                    Pool1 = fetch_pool(PoolName, State1#state.pools),
                    take_member_from_pool(Pool1, From, State1, Retries - 1);
                {max_count_reached, _} ->
                    send_metric(<<"pooler.error_no_members_count">>, {inc, 1}, counter),
                    send_metric(<<"pooler.events">>, error_no_members, history),
                    {error_no_members, State}
            end;
        [] when Retries =:= 0 ->
            %% max retries reached
            send_metric(<<"pooler.error_no_members_count">>, {inc, 1}, counter),
            {error_no_members, State};
        [Pid|Rest] ->
            erlang:link(From),
            Pool1 = Pool#pool{free_pids = Rest, in_use_count = NumInUse + 1,
                              free_count = NumFree - 1},
            send_metric(pool_metric(PoolName, in_use_count), Pool1#pool.in_use_count, histogram),
            send_metric(pool_metric(PoolName, free_count), Pool1#pool.free_count, histogram),
            {Pid, State#state{
                    pools = store_pool(PoolName, Pool1, Pools),
                    consumer_to_pid = add_member_to_consumer(Pid, From, CPMap),
                    all_members = set_cpid_for_member(Pid, From,
                                                      State#state.all_members)
                   }}
    end.

-spec do_return_member(pid(), ok | fail, #state{}) -> #state{}.
do_return_member(Pid, ok, #state{} = State) ->
    {PoolName, CPid, _} = dict:fetch(Pid, State#state.all_members),
    Pool = fetch_pool(PoolName, State#state.pools),
    #pool{free_pids = Free, in_use_count = NumInUse,
          free_count = NumFree} = Pool,
    Pool1 = Pool#pool{free_pids = [Pid | Free], in_use_count = NumInUse - 1,
                      free_count = NumFree + 1},
    Entry = {PoolName, free, os:timestamp()},
    State#state{pools = store_pool(PoolName, Pool1, State#state.pools),
                all_members = store_all_members(Pid, Entry,
                                                State#state.all_members),
                consumer_to_pid = cpmap_remove(Pid, CPid,
                                               State#state.consumer_to_pid)};
do_return_member(Pid, fail, #state{all_members = AllMembers} = State) ->
    % for the fail case, perhaps the member crashed and was alerady
    % removed, so use find instead of fetch and ignore missing.
    case dict:find(Pid, AllMembers) of
        {ok, {PoolName, _, _}} ->
            State1 = remove_pid(Pid, State),
            case add_pids(PoolName, 1, State1) of
                {Status, State2} when Status =:= ok;
                                      Status =:= max_count_reached ->
                    State2;
                {Status, _} ->
                    erlang:error({error, "unexpected return from add_pid",
                                  Status, erlang:get_stacktrace()}),
                    send_metric(<<"pooler.events">>, bad_return_from_add_pid,
                                history)
            end;
        error ->
            State
    end.

% @doc Remove `Pid' from the pid list associated with `CPid' in the
% consumer to member map given by `CPMap'.
%
% If `Pid' is the last element in `CPid's pid list, then the `CPid'
% entry is removed entirely.
%
-spec cpmap_remove(pid(), pid() | free, dict()) -> dict().
cpmap_remove(_Pid, free, CPMap) ->
    CPMap;
cpmap_remove(Pid, CPid, CPMap) ->
    case dict:find(CPid, CPMap) of
        {ok, Pids0} ->
            unlink(CPid), % FIXME: flush msg queue here?
            Pids1 = lists:delete(Pid, Pids0),
            case Pids1 of
                [_H|_T] ->
                    dict:store(CPid, Pids1, CPMap);
                [] ->
                    dict:erase(CPid, CPMap)
            end;
        error ->
            % FIXME: this shouldn't happen, should we log or error?
            CPMap
    end.

% @doc Remove and kill a pool member.
%
% Handles in-use and free members.  Logs an error if the pid is not
% tracked in state.all_members.
%
-spec remove_pid(pid(), #state{}) -> #state{}.
remove_pid(Pid, State) ->
    #state{all_members = AllMembers, pools = Pools,
           consumer_to_pid = CPMap} = State,
    case dict:find(Pid, AllMembers) of
        {ok, {PoolName, free, _Time}} ->
            % remove an unused member
            Pool = fetch_pool(PoolName, Pools),
            FreePids = lists:delete(Pid, Pool#pool.free_pids),
            NumFree = Pool#pool.free_count - 1,
            Pool1 = Pool#pool{free_pids = FreePids, free_count = NumFree},
            exit(Pid, kill),
            send_metric(<<"pooler.killed_free_count">>, {inc, 1}, counter),
            State#state{pools = store_pool(PoolName, Pool1, Pools),
                        all_members = dict:erase(Pid, AllMembers)};
        {ok, {PoolName, CPid, _Time}} ->
            Pool = fetch_pool(PoolName, Pools),
            Pool1 = Pool#pool{in_use_count = Pool#pool.in_use_count - 1},
            exit(Pid, kill),
            send_metric(<<"pooler.killed_in_use_count">>, {inc, 1}, counter),
            State#state{pools = store_pool(PoolName, Pool1, Pools),
                        consumer_to_pid = cpmap_remove(Pid, CPid, CPMap),
                        all_members = dict:erase(Pid, AllMembers)};
        error ->
            error_logger:error_report({unknown_pid, Pid,
                                       erlang:get_stacktrace()}),
            send_metric(<<"pooler.event">>, unknown_pid, history),
            State
    end.

-spec max_free_pool(dict()) -> error_no_members | string().
max_free_pool(Pools) ->
    case dict:fold(fun fold_max_free_count/3, {"", 0}, Pools) of
        {"", 0} -> error_no_members;
        {MaxFreePoolName, _} -> MaxFreePoolName
    end.

-spec fold_max_free_count(string(), #pool{}, {string(), non_neg_integer()}) ->
    {string(), non_neg_integer()}.
fold_max_free_count(Name, Pool, {CName, CMax}) ->
    case Pool#pool.free_count > CMax of
        true -> {Name, Pool#pool.free_count};
        false -> {CName, CMax}
    end.

%% @doc Returns pool with the most available members.
-spec max_avail_pool(dict()) -> error_no_members | string().
max_avail_pool(Pools) ->
    case dict:fold(fun fold_max_avail_count/3, {"", 0}, Pools) of
        {"", 0} -> error_no_members;
        {MaxAvailPoolName, _} -> MaxAvailPoolName
    end.

-spec fold_max_avail_count(string(), #pool{}, {string(), non_neg_integer()}) ->
    {string(), non_neg_integer()}.
fold_max_avail_count(Name, Pool, {CName, CMax}) ->
    Available = Pool#pool.max_count - Pool#pool.in_use_count,
    case Available > CMax of
        true -> {Name, Available};
        false -> {CName, CMax}
    end.

-spec start_n_pids(non_neg_integer(), string(), pid(), dict()) ->
    {dict(), [pid()]}.
start_n_pids(N, PoolName, PoolSup, AllMembers) ->
    NewPids = do_n(N, fun(Acc) ->
                              case supervisor:start_child(PoolSup, []) of
                                  {ok, Pid} ->
                                      erlang:link(Pid),
                                      [Pid | Acc];
                                  _Else ->
                                      Acc
                              end
                      end, []),
    AllMembers1 = lists:foldl(
                    fun(M, Dict) ->
                            Entry = {PoolName, free, os:timestamp()},
                            store_all_members(M, Entry, Dict)
                    end, AllMembers, NewPids),
    {AllMembers1, NewPids}.

do_n(0, _Fun, Acc) ->
    Acc;
do_n(N, Fun, Acc) ->
    do_n(N - 1, Fun, Fun(Acc)).


-spec fetch_pool(string(), dict()) -> #pool{} | error_no_pool.
fetch_pool(PoolName, Pools) ->
    case dict:find(PoolName, Pools) of
        {ok, Pool} -> Pool;
        error -> error_no_pool
    end.

pool_add_retries(#pool{add_member_retry = Retries}) ->
    Retries;
pool_add_retries(error_no_pool) ->
    0.

-spec store_pool(string(), #pool{}, dict()) -> dict().
store_pool(PoolName, Pool = #pool{}, Pools) ->
    dict:store(PoolName, Pool, Pools).

-spec store_all_members(pid(),
                        {string(), free | pid(), {_, _, _}}, dict()) -> dict().
store_all_members(Pid, Val = {_PoolName, _CPid, _Time}, AllMembers) ->
    dict:store(Pid, Val, AllMembers).

-spec set_cpid_for_member(pid(), pid(), dict()) -> dict().
set_cpid_for_member(MemberPid, CPid, AllMembers) ->
    dict:update(MemberPid,
                fun({PoolName, free, Time = {_, _, _}}) ->
                        {PoolName, CPid, Time}
                end, AllMembers).

-spec add_member_to_consumer(pid(), pid(), dict()) -> dict().
add_member_to_consumer(MemberPid, CPid, CPMap) ->
    dict:update(CPid, fun(O) -> [MemberPid|O] end, [MemberPid], CPMap).

-spec cull_members(string(), #state{}) -> #state{}.
cull_members(PoolName, #state{pools = Pools} = State) ->
    Pool = fetch_pool(PoolName, Pools),
    cull_members_from_pool(Pool, State).

-spec cull_members_from_pool(#pool{}, #state{}) -> #state{}.
cull_members_from_pool(error_no_pool, State) ->
    State;
cull_members_from_pool(#pool{cull_interval = {0, _}}, State) ->
    %% 0 cull_interval means do not cull
    State;
cull_members_from_pool(#pool{name = PoolName,
                             free_count = FreeCount,
                             init_count = InitCount,
                             in_use_count = InUseCount,
                             cull_interval = Delay,
                             max_age = MaxAge} = Pool,
                       #state{all_members = AllMembers} = State) ->
    MaxCull = FreeCount - (InitCount - InUseCount),
    State1 = case MaxCull > 0 of
                 true ->
                     MemberInfo = member_info(Pool#pool.free_pids, AllMembers),
                     ExpiredMembers =
                         expired_free_members(MemberInfo, os:timestamp(), MaxAge),
                     CullList = lists:sublist(ExpiredMembers, MaxCull),
                     lists:foldl(fun({CullMe, _}, S) -> remove_pid(CullMe, S) end,
                                 State, CullList);
                 false ->
                     State
             end,
    schedule_cull(PoolName, Delay),
    State1.

-spec schedule_cull(PoolName :: string(), Delay :: time_spec()) -> reference().
%% @doc Schedule a pool cleaning or "cull" for `PoolName' in which
%% members older than `max_age' will be removed until the pool has
%% `init_count' members. Uses `erlang:send_after/3' for light-weight
%% timer that will be auto-cancelled upon pooler shutdown.
schedule_cull(PoolName, Delay) ->
    DelayMillis = time_as_millis(Delay),
    %% use pid instead of server name atom to take advantage of
    %% automatic cancelling
    erlang:send_after(DelayMillis, self(), {cull_pool, PoolName}).

-spec member_info([pid()], dict()) -> [{pid(), member_info()}].
member_info(Pids, AllMembers) ->
    [ {P, dict:fetch(P, AllMembers)} || P <- Pids ].

-spec expired_free_members(Members :: [{pid(), member_info()}],
                           Now :: {_, _, _},
                           MaxAge :: time_spec()) -> [{pid(), free_member_info()}].
expired_free_members(Members, Now, MaxAge) ->
    MaxMicros = time_as_micros(MaxAge),
    [ MI || MI = {_, {_, free, LastReturn}} <- Members,
            timer:now_diff(Now, LastReturn) >= MaxMicros ].

-spec send_metric(Name :: metric_label(),
                  Value :: metric_value(),
                  Type :: metric_type()) -> ok.
%% Send a metric using the metrics module from application config or
%% do nothing.
send_metric(Name, Value, Type) ->
    case application:get_env(pooler, metrics_module) of
        undefined -> ok;
        {ok, Mod} -> Mod:notify(Name, Value, Type)
    end,
    ok.

-spec pool_metric(string(), 'free_count' | 'in_use_count' | 'take_rate') -> binary().
pool_metric(PoolName, Metric) ->
    iolist_to_binary([<<"pooler.">>, PoolName, ".",
                      atom_to_binary(Metric, utf8)]).

-spec time_as_millis(time_spec()) -> non_neg_integer().
%% @doc Convert time unit into milliseconds.
time_as_millis({Time, Unit}) ->
    time_as_micros({Time, Unit}) div 1000.

-spec time_as_micros(time_spec()) -> non_neg_integer().
%% @doc Convert time unit into microseconds
time_as_micros({Time, min}) ->
    60 * 1000 * 1000 * Time;
time_as_micros({Time, sec}) ->
    1000 * 1000 * Time;
time_as_micros({Time, ms}) ->
    1000 * Time;
time_as_micros({Time, mu}) ->
    Time.

%% @doc Pool worker status.
%% Returns list of proplist with attributes
%% id, name, capacity, created, checkedout, free, available
%%
pool_status(#state{pools=Pools} = _State) ->
    Ids = dict:fetch_keys(Pools),
    [pool_status(Id, dict:fetch(Id, Pools)) || Id <- Ids].
pool_status(Id, #pool{max_count=MaxCount,
                      free_count=Free,
                      in_use_count=CheckedOut} = _Pool) ->
    Capacity = MaxCount,
    Created = CheckedOut + Free,
    Available = Capacity - CheckedOut,
    [{id, Id},
     {capacity, Capacity},
     {created, Created},
     {checkedout, CheckedOut},
     {free, Free},
     {available, Available}].

%% @doc Returns a formatted string with pool status.
%% Includes a header and total line.
pool_status_string(#state{} = State) ->
    StatusList = pool_status(State),
    [pool_header_string()|
         [pool_status_string(Status) || Status <- StatusList]]
      ++ [pool_status_string(pool_status_total(StatusList))];
pool_status_string(PoolStatus) ->
    [{id, Id},
     {capacity, Capacity},
     {created, Created},
     {checkedout, CheckedOut},
     {free, Free},
     {available, Available}] = PoolStatus,
    io_lib:format("~-6s ~10w ~10w ~10w ~10w ~10w~n",
           [Id, Capacity, Created, CheckedOut, Free, Available]).

%% Returns a pool status proplist with special id "Total"
%% with totals for capacity, created, checkedout, free, available.
pool_status_total(PoolStatusList) ->
    [TotalCapacity,
     TotalCreated,
     TotalCheckedOut,
     TotalFree,
     TotalAvailable] = sum_attributes(PoolStatusList,
        [capacity, created, checkedout, free, available]),
    [{id, "Total"},
     {capacity, TotalCapacity},
     {created, TotalCreated},
     {checkedout, TotalCheckedOut},
     {free, TotalFree},
     {available, TotalAvailable}].

pool_header_string() ->
    io_lib:format("~-6s ~10s ~10s ~10s ~10s ~10s~n",
        ["Id", "Capacity", "Created", "CheckedOut", "Free", "Available"]).

%% @doc Transpose proplists, i.e.
%%
%% 1> transpose([[{a, 1}, {b, 2}], [{a, 3}, {b, 4}]]).
%% [{a,[1, 3]},{b,[2,4]}]
%%
transpose(PropLists) ->
    Flattened = lists:flatten(PropLists),
    [{Key, proplists:get_all_values(Key, Flattened)}
     || Key <- proplists:get_keys(Flattened)].

%% @doc Return list of sum of each attribute
%%
%% 1> sum_attributes([[{a, 1}, {b, 2}], [{a, 3}, {b, 4}]], [a, b]).
%% [4,6]
%%
sum_attributes(PropLists, Attributes) ->
    Transposed = transpose(PropLists),
    [lists:sum(proplists:get_value(Key, Transposed, [])) || Key <- Attributes].
