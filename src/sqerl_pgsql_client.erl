%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Mark Anderson <mark@opscode.com>
%% @copyright Copyright 2011 Opscode, Inc.
%% @end
%% @doc Abstraction around interacting with pgsql databases
-module(sqerl_pgsql_client).

-behaviour(sqerl_client).

-include_lib("epgsql/include/pgsql.hrl").

%% API
-export([start_link/1]).

%% sqerl_client callbacks
-export([init/1,
         exec_prepared_statement/3,
         exec_prepared_select/3,
         is_connected/1]).

-record(state,  {cn,
                 statements = dict:new() :: dict(),
                 ctrans :: dict() | undefined }).

-record(prepared_statement,
        {name :: string(),
         input_types  :: any(),
         output_fields :: any(),
         stmt :: any() } ).

-type connection() :: pid().
-type state() :: any().

-define(PING_QUERY, <<"SELECT 'pong' as ping LIMIT 1">>).

start_link(Config) ->
    sqerl_client:start_link(?MODULE, Config).

-spec exec_prepared_select(atom(), [], state()) -> {{ok, [[tuple()]]} | {error, any()}, state()}.
exec_prepared_select(Name, Args, #state{cn=Cn, statements=Statements, ctrans=CTrans}=State) ->
    PrepStmt = dict:fetch(Name, Statements),
    Stmt = PrepStmt#prepared_statement.stmt,
    NArgs = input_transforms(Args, PrepStmt, State),
    ok = pgsql:bind(Cn, Stmt, NArgs),
    %% Note: we might get partial results here for big selects!
    Result = pgsql:execute(Cn, Stmt),
    case Result of
        {ok, RowData} ->
            Rows = unpack_rows(PrepStmt, RowData),
            TRows = sqerl_transformers:by_column_name(Rows, CTrans),
            {{ok, TRows}, State};
        Result ->
            {{error, Result}, State}
    end.

-spec exec_prepared_statement(atom(), [], any()) -> {{ok, integer()} | {error, any()}, state()}.
exec_prepared_statement(Name, Args, #state{cn=Cn, statements=Statements}=State) ->
    PrepStmt = dict:fetch(Name, Statements),
    Stmt = PrepStmt#prepared_statement.stmt,
    NArgs = input_transforms(Args, PrepStmt, State),
    %% binds parameters and the named prepared statement to the unnamed portal
    ok = pgsql:bind(Cn, Stmt, NArgs),
    Rv =
        try
            %% This is equivalent to pgsql:execute(Cn, Stmt, "", 0) where the "" indicates
            %% the unnamed portal and 0 means return all result rows. Note that if we did
            %% specify a non-zero value, it looks like the pgsql:execute function handles
            %% the aggregation of partial results for us (not sure what the point is, though
            %% since I would think one would only use a non-zero value to avoid pulling the
            %% entire result set into memory).
            case pgsql:execute(Cn, Stmt) of
                {ok, Count} ->
                    %% I don't think the squery based COMMIT/ROLLBACK is the best way to
                    %% handle execution. Based on the code path of pgsql:equery, I think we
                    %% want to pgsql:close/2 and then pgsql:sync after execute. Although
                    %% reading the protocol flow docs
                    %% (http://www.postgresql.org/docs/9.1/static/protocol-flow.html) I
                    %% don't understand why we'd call close when using the unnamed portal,
                    %% but it should not hurt. It should be that calling sync is enough to
                    %% triggle a "close" on the current transaction such that we rollback on
                    %% error and otherwise commit. Hmm, on second though equery is issuing
                    %% the close because the statement is not persistent (it calls parse on
                    %% each call). So we just want sync (whether we received an error or
                    %% not).
                    commit(Cn, Count, State);
                Result ->
                    rollback(Cn, {error, Result}, State)
            end
        catch
            _:X ->
                rollback(Cn, {error, X}, State)
        end,
    Rv.

is_connected(#state{cn=Cn}=State) ->
    case catch pgsql:squery(Cn, ?PING_QUERY) of
        {ok, _, _} ->
            {true, State};
        _ ->
            false
    end.

init(Config) ->
    {host, Host} = lists:keyfind(host, 1, Config),
    {port, Port} = lists:keyfind(port, 1, Config),
    {user, User} = lists:keyfind(user, 1, Config),
    {pass, Pass} = lists:keyfind(pass, 1, Config),
    {db, Db} = lists:keyfind(db, 1, Config),
    {prepared_statement_source, PreparedStatementFile} = lists:keyfind(prepared_statement_source, 1, Config),
    Opts = [{database, Db}, {port, Port}],
    CTrans =
        case lists:keyfind(column_transforms, 1, Config) of
            {column_transforms, CT} -> CT;
            false -> undefined
        end,
    case pgsql:connect(Host, User, Pass, Opts) of
        {error, timeout} ->
            {stop, timeout};
        {ok, Connection} ->
            %% Link to pid so if this process dies we clean up
            %% the socket
            erlang:link(Connection),
            erlang:process_flag(trap_exit, true),
            {ok, Statements} = file:consult(PreparedStatementFile),
            {ok, Prepared} = load_statements(Connection, Statements, dict:new()),
            {ok, #state{cn=Connection, statements=Prepared, ctrans=CTrans}};
        {error, {syntax, Msg}} ->
            {stop, {syntax, Msg}};
        X ->
            {stop, X}
    end.

%% Internal functions
-spec load_statements(connection(), [tuple()], dict()) -> {ok, dict()} |  {error, any()}.
load_statements(_Connection, [], Dict) ->
    {ok, Dict};
load_statements(Connection, [{Name, SQL}|T], Dict) when is_atom(Name) ->
    case pgsql:parse(Connection, atom_to_list(Name), SQL, []) of
        {ok, Statement} ->
            {ok, {statement, SName, Desc, DataTypes}} = pgsql:describe(Connection, Statement),
            ColumnData = [ {CN, CT} || {column, CN, CT, _, _, _} <- Desc ],
            P = #prepared_statement{
              name = SName,
              input_types = DataTypes,
              output_fields = ColumnData,
              stmt = Statement},
            load_statements(Connection, T, dict:store(Name, P, Dict));
        {error, {error, error, _ErrorCode, Msg, Position}} ->
            {error, {syntax, {Msg, Position}}};
        Error ->
            %% TODO: Discover what errors can flow out of this, and write tests.
            {error, Error}
    end.

%% Converts contents of result_packet into our "standard"
%% representation of a list of proplists. In other words,
%% each row is converted into a proplist and then collected
%% up into a list containing all the converted rows for
%% a given query result.

-spec unpack_rows(any(), [[any()]]) -> [[{any(), any()}]].
unpack_rows(#prepared_statement{output_fields=ColumnData}, RowData) ->
    Columns = [C || {C,_} <- ColumnData],
    [ lists:zip(Columns, tuple_to_list(Row)) || Row <- RowData ].


%%%
%%% Simple hooks to support coercion inputs to match the type expected by pgsql
%%%
transform(timestamp, {datetime, X}) ->
    X;
transform(timestamp, X) when is_binary(X) ->
    sqerl_transformers:parse_timestamp_to_datetime(X);
transform(_Type, X) ->
    X.

input_transforms(Data, #prepared_statement{input_types=Types}, _State) ->
    [ transform(T, E) || {T,E} <- lists:zip(Types, Data) ].

commit(Cn, Result, State) ->
    case pgsql:squery(Cn, "COMMIT") of
        {ok, [], []} ->
            {{ok, Result}, State};
        Error when is_tuple(Error) ->
            {Error, State}
    end.

rollback(Cn, Error, State) ->
    case pgsql:squery(Cn, "ROLLBACK") of
        {ok, [], []} ->
            {Error, State};
        _Err ->
            {Error, State}
    end.
