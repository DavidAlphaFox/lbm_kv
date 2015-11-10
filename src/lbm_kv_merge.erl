%%%=============================================================================
%%%
%%%               |  o __   _|  _  __  |_   _       _ _   (TM)
%%%               |_ | | | (_| (/_ | | |_) (_| |_| | | |
%%%
%%% @copyright (C) 2014, Lindenbaum GmbH
%%%
%%% Permission to use, copy, modify, and/or distribute this software for any
%%% purpose with or without fee is hereby granted, provided that the above
%%% copyright notice and this permission notice appear in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%%
%%% @doc
%%% This module implements the `lbm_kv' table merge strategy. Currently this
%%% strategy is based on vector clocks provided in {@link lbm_kv_vclock}. If
%%% the algorithm encounters diverged entries for a specific key, it tries to
%%% call a user defined callback for the respective table. As last resort one
%%% of the nodes with conflicting tables will be restarted.
%%%
%%% For more information about user defined callbacks, refer to the {@lbm_kv}
%%% behaviour description.
%%% @end
%%%=============================================================================

-module(lbm_kv_merge).

%% Internal API
-export([tables/2]).

%% Remoting API
-export([handle_actions/1]).

-include("lbm_kv.hrl").

%%%=============================================================================
%%% Internal API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%% This function runs inside the {@link mnesia_schema:merge_schema/1}
%% transaction locking all tables to merge. However, since the merged schema
%% must first be committed to be able to make ACID compliant writes, all table
%% merge actions must be dirty opertations.
%%
%% It is sufficient to merge from an arbitrary node from the passed island. The
%% other island should already be consistent. Although dirty, merge actions will
%% be replicated to the other nodes of the island.
%%------------------------------------------------------------------------------
-spec tables([lbm_kv:table()], [node()]) -> ok | {error, term()}.
tables(_Tables, []) ->
    ok;
tables(Tables, [Node | _]) ->
    ?LBM_KV_DBG("Merging with ~s:~n", [Node]),
    tables(Tables, Node, ok).
tables([Table | Tables], Node, ok) ->
    ?LBM_KV_DBG(" * ~w~n", [Table]),
    tables(Tables, Node, merge_table(Node, Table));
tables(_, _, Result) ->
    Result.

%%------------------------------------------------------------------------------
%% @private
%% This is an internal remoting API function that handles remote merge actions.
%%------------------------------------------------------------------------------
-spec handle_actions([{atom(), [term()]}]) -> ok.
handle_actions(Actions) -> lists:foreach(fun handle_action/1, Actions).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%% Merges the values found in `Table' from the local and `Remote' node.
%%------------------------------------------------------------------------------
merge_table(Remote, Table) ->
    Keys = get_all_keys([node(), Remote], Table),
    case merge_entries(Keys, node(), Remote, Table, {[], []}) of
        {ok, {LocalActions, RemoteActions}} ->
            case rpc_actions(Remote, RemoteActions) of
                ok    -> rpc_actions(node(), LocalActions);
                Error -> Error
            end;
        Error ->
            Error
    end.

%%------------------------------------------------------------------------------
%% @private
%% Returns the local and remote merge actions for a table.
%%------------------------------------------------------------------------------
merge_entries([], _, _, _, Acc) ->
    {ok, Acc};
merge_entries([Key | Keys], Local, Remote, Table, Acc = {LAcc, RAcc}) ->
    case merge_entry(Local, Remote, Table, Key) of
        {all, Action} ->
            ?LBM_KV_DBG("   - ~w => {all,~w}~n", [Key, Action]),
            NewAcc = {[Action | LAcc], [Action | RAcc]},
            merge_entries(Keys, Local, Remote, Table, NewAcc);
        {local, Action} ->
            ?LBM_KV_DBG("   - ~w => {local,~w}~n", [Key, Action]),
            NewAcc = {[Action | LAcc], RAcc},
            merge_entries(Keys, Local, Remote, Table, NewAcc);
        {remote, Action} ->
            ?LBM_KV_DBG("   - ~w => {remote,~w}~n", [Key, Action]),
            NewAcc = {LAcc, [Action | RAcc]},
            merge_entries(Keys, Local, Remote, Table, NewAcc);
        noop ->
            ?LBM_KV_DBG("   - ~w => noop~n", [Key]),
            merge_entries(Keys, Local, Remote, Table, Acc);
        Error = {error, _} ->
            Error
    end.

%%------------------------------------------------------------------------------
%% @private
%% Return the merge action for `Key' in `Table'. All dirty mnesia operations
%% are allowed as merge actions. The returned action must be of the form
%% `noop' or `{all | local | remote, {DirtyMnesiaFunction, FunctionArgs}}'.
%%------------------------------------------------------------------------------
merge_entry(Local, Remote, Table, Key) ->
    case {get_entries(Local, Table, Key), get_entries(Remote, Table, Key)} of
        {[], []} ->
            noop;
        {[Entry], []} ->
            {remote, {dirty_write, [Entry]}};
        {[], [Entry]} ->
            {local, {dirty_write, [Entry]}};
        {[?LBM_KV_LONG(_, _, V, _)], [Entry = ?LBM_KV_LONG(_, _, V, _)]} ->
            {local, {dirty_write, [Entry]}};
        {[L = ?LBM_KV_LONG(_, _, _, LC)], [R = ?LBM_KV_LONG(_, _, _, RC)]} ->
            case lbm_kv_vclock:descends(LC, RC) of
                true ->
                    {remote, {dirty_write, [L]}};
                false ->
                    case lbm_kv_vclock:descends(RC, LC) of
                        true  -> {local, {dirty_write, [R]}};
                        false -> user_resolve_conflict(Table, Key, L, R)
                    end
            end;
        {{error, Reason}, _} ->
            {error, {Local, Reason}};
        {_, {error, Reason}} ->
            {error, {Remote, Reason}}
    end.

%%------------------------------------------------------------------------------
%% @private
%% Call a user provided function to resolve a conflicting entry. This can happen
%% on an arbitrary node (the one that connects the nodes and merges the
%% schemas).
%%
%% For more information refer to the {@lbm_kv} behaviour description.
%%------------------------------------------------------------------------------
user_resolve_conflict(Table,
                      Key,
                      L = ?LBM_KV_LONG(_, _, LV, _),
                      R = ?LBM_KV_LONG(_, _, RV, _)) ->
    Error = {error, {diverged, Table, Key}},
    case code:ensure_loaded(Table) of
        {module, Table} ->
            case erlang:function_exported(Table, resolve_conflict, 3) of
                true ->
                    case catch Table:resolve_conflict(Key, LV, RV) of
                        {value, LV} ->
                            {remote, {dirty_write, [L]}};
                        {value, RV} ->
                            {local, {dirty_write, [R]}};
                        {value, V} ->
                            Clock = lbm_kv_vclock:fresh(),
                            Version = lbm_kv_vclock:increment(node(), Clock),
                            E = ?LBM_KV_LONG(Table, Key, V, Version),
                            {all, {dirty_write, [E]}};
                        delete ->
                            {all, {dirty_delete, [Table, Key]}};
                        _ ->
                            noop
                    end;
                false ->
                    Error
            end;
        _ ->
            Error
    end.

%%------------------------------------------------------------------------------
%% @private
%% Returns the record for `Key' on `Node'.
%%------------------------------------------------------------------------------
get_entries(Node, Table, Key) -> rpc_mnesia(Node, dirty_read, [Table, Key]).

%%------------------------------------------------------------------------------
%% @private
%% Return the list of keys of `Table' on `Nodes'.
%%------------------------------------------------------------------------------
get_all_keys(Nodes, Table) ->
    lists:usort([K || N <- Nodes, K <- rpc_mnesia(N, dirty_all_keys, [Table])]).

%%------------------------------------------------------------------------------
%% @private
%% Make an RPC call to the mnesia module on node `Node'. The `rpc' module knows
%% when a call is local and optimizes that.
%%------------------------------------------------------------------------------
rpc_mnesia(Node, Function, Args) ->
    check_rpc(rpc:call(Node, mnesia, Function, Args, ?LBM_KV_RPC_TIMEOUT)).

%%------------------------------------------------------------------------------
%% @private
%% Make an RPC call to this module on `Node' handing over merge actions.
%%------------------------------------------------------------------------------
rpc_actions(_Node, []) ->
    ok;
rpc_actions(Node, Actions) ->
    Timeout = ?LBM_KV_RPC_TIMEOUT + length(Actions) * 100,
    check_rpc(rpc:call(Node, ?MODULE, handle_actions, [Actions], Timeout)).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_action({Function, Args}) -> erlang:apply(mnesia, Function, Args).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
check_rpc({badrpc, Reason}) -> {error, Reason};
check_rpc(Result)           -> Result.
