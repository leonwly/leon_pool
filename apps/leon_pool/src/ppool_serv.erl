%%%-------------------------------------------------------------------
%%% @author wangliangyou
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 03. 八月 2018 10:50
%%%-------------------------------------------------------------------
-module(ppool_serv).
-author("wangliangyou").

-behaviour(gen_server).

%% API
-export([
	start/4,
	start_link/4,
	run/2,
	sync_queue/2,
	async_queue/2,
	stop/1
]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-define(SERVER, ?MODULE).

%% The friendly supervisor is started dynamically!
-define(SPEC(MFA),
	#{
		id => worker_sup,
		start => {ppool_worker_sup, start_link, [MFA]},
		restart => temporary,
		shutdow => 10000,
		type => supervisor,
		modules => [ppool_worker_sup]
	}
).

-record(state, {limit=0, sup, refs, queue=queue:new()}).

%%%===================================================================
%%% API
%%%===================================================================

start(Name, Limit, Sup, MFA) when is_atom(Name), is_integer(Limit) ->
	gen_server:start({local, Name}, ?MODULE, {Limit, MFA, Sup}, []).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
start_link(Name, Limit, Sup, MFA) when is_atom(Name), is_integer(Limit) ->
	gen_server:start_link({local, Name}, ?MODULE, {Limit, MFA, Sup}, []).

run(Name, Args) ->
	gen_server:call(Name, {run, Args}).

sync_queue(Name, Args) ->
	gen_server:call(Name, {sync, Args}, infinite).

async_queue(Name, Args) ->
	gen_server:cast(Name, {async, Args}).

stop(Name) ->
	gen_server:call(Name, stop).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
	{ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term()} | ignore).
init({Limit, MFA, Sup}) ->
	self() ! {start_worker_supervisor, Sup, MFA},
	{ok, #state{limit = Limit, refs = gb_sets:empty()}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
	State :: #state{}) ->
	{reply, Reply :: term(), NewState :: #state{}} |
	{reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
	{noreply, NewState :: #state{}} |
	{noreply, NewState :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
	{stop, Reason :: term(), NewState :: #state{}}).

handle_call({run, Args}, _From, State=#state{limit = N, sup = Sup, refs = Refs}) when N > 0 ->
	{ok, Pid} = supervisor:start_child(Sup, Args),
	Ref = erlang:monitor(process, Pid),
	{reply, {ok, Pid}, State#state{limit = N - 1, refs = gb_sets:add(Ref, Refs)}};
handle_call({run, _Args}, _From, State=#state{limit = N}) when N =< 0 ->
	{reply, noalloc, State};

handle_call({sync, Args}, _From, State=#state{limit = N, sup = Sup, refs = Refs}) when N > 0 ->
	{ok, Pid} = supervisor:start_child(Sup, Args),
	Ref = erlang:monitor(process, Pid),
	{reply, {ok, Pid}, State#state{limit = N - 1, refs = gb_sets:add(Ref, Refs)}};
handle_call({sync, Args}, From, State=#state{queue = Queue}) ->
	{noreply, State#state{queue = queue:in({Args, From}, Queue)}};

handle_call(stop, _From, State) ->
	{stop, normal, ok, State};

handle_call(_Request, _From, State) ->
	{reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
	{noreply, NewState :: #state{}} |
	{noreply, NewState :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: #state{}}).

handle_cast({async, Args}, State=#state{limit = N, sup = Sup, refs = Refs}) when N > 0 ->
	{ok, Pid} = supervisor:start_child(Sup, Args),
	Ref = erlang:monitor(process, Pid),
	{noreply, State#state{limit = N - 1, refs = gb_sets:add(Ref, Refs)}};
handle_cast({async, Args}, State=#state{limit = N, queue = Queue}) when N =< 0 ->
	{noreply, State#state{queue = queue:in(Args, Queue)}};

handle_cast(_Request, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
	{noreply, NewState :: #state{}} |
	{noreply, NewState :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: #state{}}).
handle_info({start_worker_supervisor, Sup, MFA}, State) ->
	{ok, Pid} = supervisor:start_child(Sup, ?SPEC(MFA)),
	link(Pid),
	{noreply, State#state{sup = Pid}};

handle_info({'DOWN', Ref, process, _Pid, _}, State=#state{refs = Refs}) ->
	case gb_sets:is_element(Ref, Refs) of
		false ->
			{noreply, State};
		true ->
			handle_down_worker(Ref, State)
	end;

handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
	State :: #state{}) -> term()).
terminate(_Reason, _State) ->
	ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
	Extra :: term()) ->
	{ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc handle the logic after the death of worker
-spec handle_down_worker(Ref, State) -> {noreply, NewState} when
	Ref :: reference(),
	State :: #state{},
	NewState :: #state{}.
handle_down_worker(Ref, State = #state{limit = Limit, sup = Sup, refs = Refs, queue = Queue}) ->
	Refs1 = gb_sets:delete(Ref, Refs),
	case queue:out(Queue) of
		{{value, {From, Args}}, Q} ->
			{ok, Pid} = supervisor:start_child(Sup, Args),
			NewRef = erlang:monitor(process, Pid),
			NewRefs = gb_sets:add(NewRef, Refs1),
			gen_server:reply(From, {ok, Pid}),
			{noreply, State#state{refs = NewRefs, queue = Q}};
		{{value, Args}, Q} ->
			{ok, Pid} = supervisor:start_child(Sup, Args),
			NewRef = erlang:monitor(process, Pid),
			NewRefs = gb_sets:add(NewRef, Refs1),
			{noreply, State#state{refs =  NewRefs, queue = Q}};
		{empty, _} ->
			{noreply, State#state{limit = Limit + 1, refs = Refs1}}
	end.
