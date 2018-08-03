%%%-------------------------------------------------------------------
%%% @author wangliangyou
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. 八月 2018 16:31
%%%-------------------------------------------------------------------
-module(ppool_supersup).
-author("wangliangyou").

-behaviour(supervisor).

%% API
-export([
	start_link/0,
	stop/0,
	start_pool/3,
	stop_pool/1
]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ppool).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
	{ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Stop ppool super supervisor using brutally,
%% technically, a supervisor can not be killed in an easy way.
%% So, let's do it brutally.
stop() ->
	case whereis(?SERVER) of
		Pid when is_pid(Pid) -> exit(Pid, kill);
		_ -> ok
	end.

%% @doc Start pool
start_pool(Name, Limit, MFA) ->
	ChildSpec =
		#{
			id => Name,
			start => {ppool_sup, start_link, [Name, Limit, MFA]},
			restart => permanent,
			shutdown => 10500,
			type => supervisor,
			modules => [ppool_sup]
		},
	supervisor:start_child(?SERVER, ChildSpec).

%% @doc Stop pool
stop_pool(Name) ->
	supervisor:terminate_child(?SERVER, Name),
	supervisor:delete_child(?SERVER, Name).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
	{ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
		MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
		[ChildSpec :: supervisor:child_spec()]
	}} |
	ignore |
	{error, Reason :: term()}).
init([]) ->
	RestartStrategy = one_for_one,
	MaxRestarts = 6,
	MaxSecondsBetweenRestarts = 3600,
	
	SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
	
	Restart = permanent,
	Shutdown = 2000,
	Type = worker,
	
	_AChild = {'AName', {'AModule', start_link, []},
		Restart, Shutdown, Type, ['AModule']},
	
	{ok, {SupFlags, []}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
