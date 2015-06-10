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

-module(master_SUITE).

%% API
-export([all/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2]).

-export([test_zone_modify/1,
         test_georecord_match/1]).

-include("../include/erldns.hrl").
-include("../deps/dns/include/dns.hrl").
all() ->
    [test_zone_modify, test_georecord_match].

init_per_suite(Config) ->
    application:start(erldns_app),
    ok = application:set_env(erldns, servers, [
        [{port, 8053},
            {listen, [{10,1,10,51}]},
            {protocol, [tcp, udp]},
            {worker_pool, [
                {size, 10}, {max_overflow, 20}
            ]}]
    ]),
    application:set_env(erldns, storage, [{type, erldns_storage_mnesia}, {dir, "/opt/erl-dns/test/test_db1"}]),
    application:set_env(erldns, admin, [{listen, {10, 1, 10, 51}}, {port, 9000}]),
    Config.

end_per_suite(Config) ->
    application:stop(erldns_app),
    Config.

init_per_testcase(test_zone_modify, Config) ->
    ok = erldns_storage:create(schema),
    ok = erldns:start(),
    Config;
init_per_testcase(test_georecord_match, Config) ->
    Config.


test_zone_modify(_Config) ->
    %%This test should modify the zone and send a NOTIFY to slave
    erldns_storage_mnesia = erldns_config:storage_type(),
    ok = erldns_storage:create(schema),
    ok = erldns_storage:create(zones),
    {ok, _} = erldns_storage:load_zones("/opt/erl-dns/priv/example.zone.json"),
    [ok,ok,ok] = erldns_zone_cache:add_record(<<"example.com">>,
                                        {dns_rr,<<"example.com">>,1,1,3600,{dns_rrdata_a,{7,7,7,7}}}, true),
    [ok,ok,ok] = erldns_zone_cache:update_record(<<"example.com">>,
                                           {dns_rr,<<"example.com">>,1,1,3600,{dns_rrdata_a,{7,7,7,7}}},
                                           {dns_rr,<<"example.com">>,1,1,3600,{dns_rrdata_a,{77,77,77,77}}}, true),
    [ok,ok,ok] = erldns_zone_cache:delete_record(<<"example.com">>,
                                           {dns_rr,<<"example.com">>,1,1,3600,{dns_rrdata_a,{77,77,77,77}}}, true).

test_georecord_match(_Config) ->
    erldns_storage:create(geolocation),
    erldns_georegion:create_geogroup(<<"us-east">>, <<"US">>, [<<"FL">>]),
    erldns_georegion:create_lookup_table(),
    io:format("zone: ~p", [erldns_storage:list_table(zones)]),
    io:format("geolocation: ~p", [erldns_storage:list_table(geolocation)]),
    io:format("lookup table: ~p", [erldns_storage:list_table(lookup_table)]),
    {ok, {dns_rec,
          {dns_header,_,_,_,_,_,_,_,_,_},
          _,
          [{dns_rr,"_geo.us-east.example.com",_,_,_,_,_,_,_,_}],
          [],   %%NS List (Should be empty)
          []}} = inet_res:nnslookup("example.com", any, a, [{{10,1,10,51}, 8053}], 10000).
