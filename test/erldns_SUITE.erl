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

-module(erldns_SUITE).
%% API
-export([all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2]).

-export([mnesia_API_test/1,
         json_API_test/1,
         server_children_test/1]).

-include("../include/erldns.hrl").
-include("../deps/dns/include/dns.hrl").
all() ->
    [mnesia_API_test, json_API_test, server_children_test].

init_per_suite(Config) ->
    application:start(erldns_app),
    Config.

end_per_suite(Config) ->
    application:stop(erldns_app),
    Config.

init_per_testcase(mnesia_API_test, Config) ->
    application:set_env(erldns, storage, [{type, erldns_storage_mnesia}, {dir, "db"}]),
    Config;
init_per_testcase(json_API_test, Config) ->
    application:set_env(erldns, storage, [{type, erldns_storage_json}]),
    Config;
init_per_testcase(server_children_test, Config) ->
    Config.

mnesia_API_test(_Config) ->
    erldns_storage_mnesia = erldns_config:storage_type(),
    DNSRR = #dns_rr{name = <<"TEST DNSRR NAME">>, class = 1, type = 0, ttl = 0, data = <<"TEST DNSRR DATA">>},
    ZONE1 = #zone{name = <<"TEST NAME 1">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE2 = #zone{name = <<"TEST NAME 2">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE3 = #zone{name = <<"TEST NAME 3">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE4 = #zone{name = <<"TEST NAME 4">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE5 = #zone{name = <<"TEST NAME 5">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    erldns_storage:create(schema),
    erldns_storage:create(zones),
    mnesia:wait_for_tables([zones], 10000),
    erldns_storage:insert(zones, ZONE1),
    erldns_storage:insert(zones, ZONE2),
    erldns_storage:insert(zones, ZONE3),
    erldns_storage:insert(zones, {<<"Test Name">>, ZONE4}),
    erldns_storage:insert(zones, {<<"Test Name">>, ZONE5}),
    %%Iterate through table and see all the entrys.
    Iterator =  fun(Rec,_)->
        io:format("~p~n",[Rec]),
        []
    end,
    erldns_storage:foldl(Iterator, [], zones),
    erldns_storage:select(zones, <<"TEST NAME 1">>),
    erldns_storage:delete(zones, <<"TEST NAME 1">>),
    erldns_storage:empty_table(zones),
    erldns_storage:delete_table(zones),
    %%authority test
    erldns_storage:create(authorities),
    mnesia:wait_for_tables([authorities], 10000),
    AUTH1 = #authorities{owner_name = <<"Test Name">>, ttl = 1, class = <<"test calss">>, name_server = <<"Test Name Server">>,
        email_addr = <<"test email">>, serial_num = 1, refresh = 1, retry = 1, expiry = 1, nxdomain = <<"test domain">>},
    AUTH2 = #authorities{owner_name = <<"Test Name">>, ttl = 1, class = <<"test calss">>, name_server = <<"Test Name Server">>,
        email_addr = <<"test email">>, serial_num = 1, refresh = 1, retry = 1, expiry = 1, nxdomain = <<"test domain">>},
    AUTH3 = #authorities{owner_name = <<"Test Name">>, ttl = 1, class = <<"test calss">>, name_server = <<"Test Name Server">>,
        email_addr = <<"test email">>, serial_num = 1, refresh = 1, retry = 1, expiry = 1, nxdomain = <<"test domain">>},
    erldns_storage:insert(authorities, AUTH1),
    erldns_storage:insert(authorities, AUTH2),
    erldns_storage:insert(authorities, AUTH3),
    erldns_storage:foldl(Iterator, [], authorities),
    erldns_storage:select(authorities, <<"Test Name">>),
    erldns_storage:delete(authorities, <<"Test Name">>),
    erldns_storage:empty_table(authorities),
    erldns_storage:delete_table(authorities),
    io:format("Test completed for mnesia API~n").

json_API_test(_Config) ->
    erldns_storage_json = erldns_config:storage_type(),
    DNSRR = #dns_rr{name = <<"TEST DNSRR NAME">>, class = 1, type = 0, ttl = 0, data = <<"TEST DNSRR DATA">>},
    ZONE1 = #zone{name = <<"TEST NAME 1">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE2 = #zone{name = <<"TEST NAME 2">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE3 = #zone{name = <<"TEST NAME 3">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE4 = #zone{name = <<"TEST NAME 4">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    ZONE5 = #zone{name = <<"TEST NAME 5">>, version = <<"1">>,authority =  [], record_count = 0, records = [], records_by_name = DNSRR, records_by_type = DNSRR},
    erldns_storage:create(zones),
    erldns_storage:insert(zones, ZONE1),
    erldns_storage:insert(zones, ZONE2),
    erldns_storage:insert(zones, ZONE3),
    erldns_storage:insert(zones, ZONE4),
    erldns_storage:insert(zones, ZONE5),
    %%Iterate through table and see all the entrys.
    Iterator =  fun(Rec,_)->
        io:format("~p~n",[Rec]),
        []
    end,
    erldns_storage:foldl(Iterator, [], zones),
    erldns_storage:select(zones, <<"TEST NAME 1">>),
    erldns_storage:delete(zones, <<"TEST NAME 1">>),
    erldns_storage:empty_table(zones),
    erldns_storage:delete_table(zones),
    io:format("Test completed for json API~n").

server_children_test(_Config) ->
    {ok, IFAddrs} = inet:getifaddrs(),
    Config = lists:foldl(fun(IFList, Acc) ->
        {_, List} = IFList,
        [List | Acc]
             end, [], IFAddrs),
    Addresses = lists:foldl(fun(Conf, Acc) ->
        {addr, Addr} = lists:keyfind(addr, 1, Conf),
        [{Addr, 8053} | Acc]
        end, [], Config),

    application:set_env(erldns, servers, [
        [{port, 8053},
            {listen, Addresses},
            {protocol, [tcp, udp]},
            {worker_pool, [
                {size, 10}, {max_overflow, 20}
            ]}]
    ]),
    application:stop(erldns_app),
    application:start(erldns_app),
    io:format("Loaded and started servers successfully~n"),
    {ok, _} = inet_res:nnslookup("example.com", any, a, Addresses, 2000),
    io:format("Test completed for server_children~n").