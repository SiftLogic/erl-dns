%% Copyright (c) 2014, SiftLogic LLC
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(erldns_storage_json).

%% API
-export([create/1,
    insert/2,
    delete_table/1,
    delete/2,
    backup_table/1,
    backup_tables/0,
    select/2,
    select/3,
    foldl/3,
    empty_table/1]).

-spec create(atom()) -> ok.
create(zones) ->
    ok = ets:new(zones, [set, public, named_table]);
create(authorities) ->
    ok = ets:new(authorities, [set, public, named_table]);
%% These tables should always use ets.
create(packet_cache) ->
    ok = ets:new(packet_cache, [set, named_table]);
create(host_throttle) ->
    ok = ets:new(host_throttle, [set, named_table, public]);
create(handler_registry) ->
    ok = ets:new(handler_registry, [set, named_table, public]).

-spec insert(atom(), tuple()) -> ok.
insert(Key, Value)->
    ok = ets:insert(Key, Value).

-spec delete_table(atom()) -> true.
delete_table(Table)->
    ets:delete(Table).

-spec delete(atom(), term()) -> true.
delete(Table, Key) ->
    ets:delete(Table, Key).

-spec backup_table(atom()) -> ok | {error, Reason}.
backup_table(Table)->
    not_implemented.

-spec backup_tables() -> ok | {error, Reason}.
backup_tables() ->
    not_implemented.

-spec select(atom(), term()) -> tuple().
select(Key, Value) ->
    ets:lookup(Key, Value).

-spec select(atom(), list(), integer()) -> tuple() | '$end_of_table'.
select(Table, MatchSpec, Limit) ->
    ets:select(Table, MatchSpec, Limit).

-spec foldl(fun(), list(), atom())  -> Acc | {error, Reason}.
foldl(Fun, Acc, Table) ->
    ets:foldl(Fun, Acc, Table).

-spec empty_table(atom()) -> ok.
empty_table(Table) ->
    ets:delete_all_objects(Table).
