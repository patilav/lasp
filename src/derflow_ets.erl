%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(derflow_ets).
-author("Christopher Meiklejohn <cmeiklejohn@basho.com>").

-include("derflow.hrl").

%% Core API.
-export([is_det/2,
         bind/3,
         read/2,
         read/3,
         next/2,
         declare/1,
         declare/2,
         declare/3,
         thread/4,
         select/4,
         wait_needed/2,
         reply_to_all/2,
         reply_to_all/3]).

%% Exported functions for vnode integration, where callback behavior is
%% dynamic.
-export([next/3,
         bind/4,
         bind/5,
         notify_value/4,
         wait_needed/5,
         read/6,
         write/6,
         select/5,
         fetch/8]).

%% Exported helper functions.
-export([select_harness/6]).

%% Exported utility functions.
-export([threshold_met/3,
         is_lattice/1,
         is_inflation/3,
         generate_operations/2]).

%% @doc Given an identifier, return the next identifier.
next(Id, Store) ->
    DeclareNextFun = fun(Type) ->
            declare(Type, Store)
    end,
    next(Id, Store, DeclareNextFun).

%% @doc Given an identifier, return the next identifier.
%%      Allow for an override function for performing the generation of
%%      the next identifier, using `DeclareNextFun'.
%%
next(Id, Store, DeclareNextFun) ->
    [{_Key, V=#dv{next=NextKey0}}] = ets:lookup(Store, Id),
    case NextKey0 of
        undefined ->
            {ok, NextKey} = DeclareNextFun(V#dv.type),
            true = ets:insert(Store, {Id, V#dv{next=NextKey}}),
            {ok, NextKey};
        _ ->
            {ok, NextKey0}
    end.

%% @TODO implement.
select(_Id, _Function, _AccId, _Store) ->
    {error, not_implemented}.

select(Id, Function, AccId, Store, BindFun) ->
    Pid = spawn_link(?MODULE, select_harness, [Store,
                                               Id,
                                               Function,
                                               AccId,
                                               BindFun,
                                               undefined]),
    {ok, Pid}.

%% @doc Perform a read for a particular identifier.
%%
read(Id, Store) ->
    read(Id, undefined, Store).

%% @doc Perform a threshold read for a particular identifier.
%%
%%      This operation blocks until `Threshold' has been reached,
%%      reading from the provided {@link ets:new/2} store, `Store'.
%%
read(Id, Threshold, Store) ->
    Self = self(),
    ReplyFun = fun(Type, Value, Next) ->
                    {ok, Type, Value, Next}
               end,
    BlockingFun = fun() ->
                        receive
                            X ->
                                lager:info("Value: ~p", [X]),
                                X
                        end
                 end,
    read(Id, Threshold, Store, Self, ReplyFun, BlockingFun).

%% @doc  Perform a read (or threshold read) for a particular identifier.
%%
%%       Perform a read -- reads will either block until the `Threshold'
%%       is met, or the variable is bound.  Reads will be performed
%%       against the `Store' provided, which should be the identifier of
%%       an {@link ets:new/2} table.  When the process should register
%%       itself for notification of the variable being bound, it should
%%       supply the process identifier for notifications as `Self'.
%%       Finally, the `ReplyFun' and `BlockingFun' functions will be
%%       executed in the event that the reply is available immediately,
%%       or it will have to wait for the notification, in the event the
%%       variable is unbound or has not met the threshold yet.
%%
read(Id, Threshold, Store, Self, ReplyFun, BlockingFun) ->
    [{_Key, V=#dv{value=Value,
                  bound=Bound,
                  creator=Creator,
                  lazy=Lazy,
                  type=Type}}] = ets:lookup(Store, Id),
    case Bound of
        true ->
            lager:info("Read received: ~p, bound: ~p, threshold: ~p",
                       [Id, V, Threshold]),
            case ?MODULE:is_lattice(Type) of
                true ->
                    case Threshold of
                        undefined ->
                            lager:info("No threshold specified: ~p",
                                       [Threshold]),
                            ReplyFun(Type, Value, V#dv.next);
                        _ ->
                            lager:info("Threshold specified: ~p",
                                       [Threshold]),
                            case ?MODULE:threshold_met(Type,
                                                           Value,
                                                           Threshold) of
                                true ->
                                    ReplyFun(Type, Value, V#dv.next);
                                false ->
                                    WT = lists:append(V#dv.waiting_threads,
                                                      [{threshold,
                                                        Self,
                                                        Type,
                                                        Threshold}]),
                                    true = ets:insert(Store,
                                                      {Id,
                                                       V#dv{waiting_threads=WT}}),
                                    BlockingFun()
                            end
                    end;
                false ->
                    ReplyFun(Type, Value, V#dv.next)
            end;
        false ->
            lager:info("Read received: ~p, unbound", [Id]),
            WT = lists:append(V#dv.waiting_threads, [Self]),
            true = ets:insert(Store, {Id, V#dv{waiting_threads=WT}}),
            case Lazy of
                true ->
                    {ok, _} = reply_to_all([Creator], ok),
                    BlockingFun();
                false ->
                    BlockingFun()
            end
    end.

%% @doc Fetch is responsible for retreiving the value of a
%%      partially-bound variable from the ultimate source, if it's
%%      bound.
%%
%%      When running on a local replica, this is straightforward -- it¬
%%      can look the value up direclty up from the {@link ets:new/2}
%%      table supplied, as seen in the {@link bind/3} function.  Fetch
%%      is specifically used when we need to look in a series of tables,
%%      each running in a different process at a different node.
%%
%%      The function is implemented here, given it relies on knowing the
%%      structure of the table and is ets specific.  However, it's
%%      primarily used by the distribution code located in the virtual
%%      node.
%%
%%      Because of this, a number of functions need to be exported to
%%      support this behavior.
%%
%%      `ResponseFun' is a function responsible for the return value, as
%%      required by the virtual node which will call into this.
%%
%%      `FetchFun' is a function responsible for retreiving the value on
%%      another node, if the value is only partially bound here --
%%      consider the case where X is bound to Y which is bound to Z -- a
%%      fetch on Z requires transitive fetches through Y to X.
%%
%%      `ReplyFetchFun' is a function responsible for sending the
%%      response back to the originating fetch node.
%%
%%      `NextKeyFun' is responsible for generating the next identifier
%%      for use in building a stream from this partially-bound variable.
%%
fetch(TargetId, FromId, FromPid, Store,
      ResponseFun, FetchFun, ReplyFetchFun, NextKeyFun) ->
    [{_, DV=#dv{bound=Bound,
                value=Value}}] = ets:lookup(Store, TargetId),
    case Bound of
        true ->
            ReplyFetchFun(FromId, FromPid, DV),
            ResponseFun();
        false ->
            case Value of
                {id, BindId} ->
                    FetchFun(BindId, FromId, FromPid),
                    ResponseFun();
                _ ->
                    NextKey = NextKeyFun(DV#dv.next, DV#dv.type),
                    BindingList = lists:append(DV#dv.binding_list, [FromId]),
                    DV1 = DV#dv{binding_list=BindingList, next=NextKey},
                    true = ets:insert(Store, {TargetId, DV1}),
                    ReplyFetchFun(FromId, FromPid, DV1),
                    ResponseFun()
                end
    end.

%% @doc Declare a dataflow variable in a provided by identifer {@link
%%      ets:new/2} `Store'.
%%
declare(Store) ->
    declare(undefined, Store).

%% @doc Declare a dataflow variable, as a given type, in a provided by
%%      identifer {@link ets:new/2} `Store'.
%%
declare(Type, Store) ->
    declare(druuid:v4(), Type, Store).

%% @doc Declare a dataflow variable of a given type with a given id.
%%
declare(Id, Type, Store) ->
    Record = case Type of
        undefined ->
            #dv{value=undefined, type=undefined, bound=false};
        Type ->
            #dv{value=Type:new(), type=Type, bound=true}
    end,
    true = ets:insert(Store, {Id, Record}),
    {ok, Id}.

%% @doc Define a dataflow variable to be bound to another dataflow
%%      variable.
bind(Id, {id, DVId}, Store, FetchFun, FromPid) ->
    true = ets:insert(Store, {Id, #dv{value={id, DVId}}}),
    FetchFun(DVId, Id, FromPid).

%% @doc Define a dataflow variable to be bound to another dataflow
%%      variable.
%% @TODO Implement.
bind(_Id, {id, _DVId}, _Store) ->
    {error, not_implemented};

%% @doc Define a dataflow variable to be bound a value.
%%
bind(Id, Value, Store) ->
    NextKeyFun = fun(Type, Next) ->
                        case Value of
                            undefined ->
                                undefined;
                            _ ->
                                next_key(Next, Type, Store)
                        end
                 end,
    bind(Id, Value, Store, NextKeyFun).

%% @doc Define a dataflow variable to be bound a value.
%%
%%      `NextKeyFun' is used to determine how to generate the next
%%      identifier -- this is abstracted because in some settings this
%%      next key may be located in the local store, when running code at
%%      the replica, or located in a remote store, when running the code
%%      at the client.
%%
bind(Id, Value, Store, NextKeyFun) ->
    [{_Key, V=#dv{next=Next,
                  type=Type,
                  bound=Bound,
                  value=Value0}}] = ets:lookup(Store, Id),
    NextKey = NextKeyFun(Type, Next),
    case Bound of
        true ->
            case V#dv.value of
                Value ->
                    {ok, NextKey};
                _ ->
                    case is_lattice(Type) of
                        true ->
                            Merged = Type:merge(V#dv.value, Value),
                            case is_inflation(Type, V#dv.value, Merged) of
                                true ->
                                    write(Type, Merged, NextKey, Id, Store),
                                    {ok, NextKey};
                                false ->
                                    lager:error("Bind failed: ~p ~p ~p~n",
                                                [Type, Value0, Value]),
                                    error
                            end;
                        false ->
                            lager:error("Bind failed: ~p ~p ~p~n",
                                        [Type, Value0, Value]),
                            error
                    end
            end;
        false ->
            write(Type, Value, NextKey, Id, Store),
            {ok, NextKey}
    end.

%% @doc Return the binding status of a given dataflow variable.
%%
is_det(Id, Store) ->
    [{_Key, #dv{bound=Bound}}] = ets:lookup(Store, Id),
    {ok, Bound}.

%% @doc Spawn a function.
%%
thread(Module, Function, Args, _Store) ->
    Fun = fun() -> erlang:apply(Module, Function, Args) end,
    Pid = spawn(Fun),
    {ok, Pid}.

%% Internal functions

%% @doc Declare next key, if undefined.  This function assumes that the
%%      next key will be declared in the local store.
%%
next_key(undefined, Type, Store) ->
    {ok, NextKey} = declare(druuid:v4(), Type, Store),
    NextKey;
next_key(NextKey0, _, _) ->
    NextKey0.

%% @doc Determine if a threshold is met.
%%
threshold_met(riak_dt_gset, Value, {strict, Threshold}) ->
    is_strict_inflation(riak_dt_gset, Threshold, Value);
threshold_met(riak_dt_gset, Value, Threshold) ->
    is_inflation(riak_dt_gset, Threshold, Value);
threshold_met(riak_dt_gcounter, Value, {strict, Threshold}) ->
    Threshold < riak_dt_gcounter:value(Value);
threshold_met(riak_dt_gcounter, Value, Threshold) ->
    Threshold =< riak_dt_gcounter:value(Value).

%% @doc Determine if a change is an inflation or not.
%%
is_inflation(Type, Previous, Current) ->
    is_lattice(Type) andalso
        is_lattice_inflation(Type, Previous, Current).

%% @doc Determine if a change is a strict inflation or not.
%%
is_strict_inflation(Type, Previous, Current) ->
    is_lattice(Type) andalso
        is_lattice_strict_inflation(Type, Previous, Current).

%% @doc Determine if a change for a given type is an inflation or not.
%%
is_lattice_inflation(riak_dt_gcounter, undefined, _) ->
    true;
is_lattice_inflation(riak_dt_gcounter, Previous, Current) ->
    PreviousList = lists:sort(orddict:to_list(Previous)),
    CurrentList = lists:sort(orddict:to_list(Current)),
    lists:foldl(fun({Actor, Count}, Acc) ->
            case lists:keyfind(Actor, 1, CurrentList) of
                false ->
                    Acc andalso false;
                {_Actor1, Count1} ->
                    Acc andalso (Count =< Count1)
            end
            end, true, PreviousList);
is_lattice_inflation(riak_dt_gset, undefined, _) ->
    true;
is_lattice_inflation(riak_dt_gset, Previous, Current) ->
    sets:is_subset(
        sets:from_list(riak_dt_gset:value(Previous)),
        sets:from_list(riak_dt_gset:value(Current))).

%% @doc Determine if a change for a given type is a strict inflation or
%%      not.
%%
is_lattice_strict_inflation(riak_dt_gset, undefined, Current) ->
    is_lattice_inflation(riak_dt_gset, undefined, Current);
is_lattice_strict_inflation(riak_dt_gset, Previous, Current) ->
    is_lattice_inflation(riak_dt_gset, Previous, Current) andalso
        lists:usort(riak_dt_gset:value(Previous)) =/=
        lists:usort(riak_dt_gset:value(Current)).

%% @doc Return if something is a lattice or not.
%%
is_lattice(Type) ->
    lists:member(Type, ?LATTICES).

%% @doc Send responses to waiting threads, via messages.
%%
%%      Perform the following operations:
%%
%%      * Reply to all waiting threads via message.
%%      * Perform binding of any variables which are partially bound.
%%      * Mark variable as bound.
%%      * Check thresholds and send notifications, if required.
%%
write(Type, Value, Next, Key, Store) ->
    NotifyFun = fun(Id, NewValue) ->
                        [{_, #dv{next=Next,
                                 type=Type}}] = ets:lookup(Store, Id),
                        write(Type, NewValue, Next, Id, Store)
                end,
    write(Type, Value, Next, Key, Store, NotifyFun).

write(Type, Value, Next, Key, Store, NotifyFun) ->
    lager:info("Writing key: ~p next: ~p", [Key, Next]),
    [{_Key, #dv{waiting_threads=Threads,
                binding_list=BindingList,
                lazy=Lazy}}] = ets:lookup(Store, Key),
    lager:info("Waiting threads are: ~p", [Threads]),
    {ok, StillWaiting} = reply_to_all(Threads, [], {ok, Type, Value, Next}),
    V1 = #dv{type=Type,
             value=Value,
             next=Next,
             lazy=Lazy,
             bound=true,
             waiting_threads=StillWaiting},
    true = ets:insert(Store, {Key, V1}),
    notify_all(NotifyFun, BindingList, Value),
    ok.

%% @TODO implement.
wait_needed(_Id, _Store) ->
    {error, not_implemeneted}.

%% @doc Callback wait_needed function for derflow_vnode, where we
%%      change the reply and blocking replies.
%%
wait_needed(Id, Store, Self, ReplyFun, BlockingFun) ->
    lager:info("Wait needed issued for identifier: ~p", [Id]),
    [{_Key, V=#dv{waiting_threads=WT,
                  bound=Bound}}] = ets:lookup(Store, Id),
    case Bound of
        true ->
            ReplyFun();
        false ->
            case WT of
                [_H|_T] ->
                    ReplyFun();
                _ ->
                    true = ets:insert(Store,
                                      {Id, V#dv{lazy=true, creator=Self}}),
                    BlockingFun()
                end
    end.

%% @doc Notify a value and write.
notify_value(Id, Value, Store, NotifyFun) ->
    [{_, #dv{next=Next, type=Type}}] = ets:lookup(Store, Id),
    write(Type, Value, Next, Id, Store, NotifyFun).

%% @doc Notify a series of variables of bind.
%%
notify_all(NotifyFun, [H|T], Value) ->
    NotifyFun(H, Value),
    notify_all(NotifyFun, T, Value);
notify_all(_, [], _) ->
    ok.

%% @doc Given a group of processes which are blocking on reads, notify
%%      them of bound values or met thresholds.
%%
reply_to_all(List, Result) ->
    reply_to_all(List, [], Result).

%% @doc Given a group of processes which are blocking on reads, notify
%%      them of bound values or met thresholds.
%%
reply_to_all([{threshold, From, Type, Threshold}=H|T],
             StillWaiting0,
             {ok, Type, Value, Next}=Result) ->
    lager:info("Result: ~p, Threshold: ~p", [Result, Threshold]),
    StillWaiting = case ?MODULE:threshold_met(Type, Value, Threshold) of
        true ->
            lager:info("Threshold ~p met: ~p", [Threshold, Value]),
            case From of
                {server, undefined, {Address, Ref}} ->
                    gen_server:reply({Address, Ref}, {ok, Type, Value, Next});
                _ ->
                    From ! Result
            end,
            StillWaiting0;
        false ->
            lager:info("Threshold ~p NOT met: ~p", [Threshold, Value]),
            StillWaiting0 ++ [H]
    end,
    reply_to_all(T, StillWaiting, Result);
reply_to_all([From|T], StillWaiting, Result) ->
    case From of
        {server, undefined, {Address, Ref}} ->
            gen_server:reply({Address, Ref}, Result);
        _ ->
            From ! Result
    end,
    reply_to_all(T, StillWaiting, Result);
reply_to_all([], StillWaiting, _Result) ->
    {ok, StillWaiting}.

%% @doc Given an object type from riak_dt; generate a series of
%%      operations for that type which are representative of a partial
%%      order of operations on this object yielding this state.
%%
generate_operations(riak_dt_gset, Set) ->
    Values = riak_dt_gset:value(Set),
    {ok, [{add, Value} || Value <- Values]}.

%% @doc Harness for managing the select operation.
select_harness(Variables, Id, Function, AccId, BindFun, Previous) ->
    lager:info("Select executing!"),
    {ok, Type, Value, _} = ?MODULE:read(Id, {strict, Previous}, Variables),
    lager:info("Threshold was met!"),
    [{_Key, #dv{type=Type, value=Value}}] = ets:lookup(Variables, Id),

    %% Generate operations for given data type.
    {ok, Operations} = ?MODULE:generate_operations(Type, Value),
    lager:info("Operations generated: ~p", [Operations]),

    %% Build new data structure.
    AccValue = lists:foldl(
                 fun({add, Element} = Op, Acc) ->
                         case Function(Element) of
                             true ->
                                 {ok, NewAcc} = Type:update(Op, undefined, Acc),
                                 NewAcc;
                             _ ->
                                 Acc
                         end
                 end, Type:new(), Operations),
    BindFun(AccId, AccValue, Variables),
    select_harness(Variables, Id, Function, AccId, BindFun, Value).
