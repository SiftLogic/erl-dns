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

%% @doc Handles admin server. A started slave will wuery this server in order to get the zones
%% it should have. Then it shall initiate an AXFR request to the master.
%% @end

-module(erldns_admin_server).
-behavior(gen_nb_server).

-include("erldns.hrl").

%% API
-export([start_link/3]).

%% Gen server hooks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         sock_opts/0,
         new_connection/2,
         code_change/3
        ]).

-export([create_geogroup/3,
         delete_geogroup/1,
         update_geogroup/2,
         list_geogroups/0]).

%% Internal API

-define(SERVER, ?MODULE).

-record(state, {port, listen_ip}).

%% Public API
start_link(_Name, ListenIP, Port) ->
    erldns_log:info("Starting ADMIN server on port ~p, IP ~p", [Port, ListenIP]),
    ok = erldns_storage:create(geolocation),
    create_lookup_table(),
    gen_nb_server:start_link({local, ?MODULE}, ListenIP, Port, [Port, ListenIP]).

%% Geo-location API
%% @doc Adds a new geogroup to the DB.
%% NOTE: Because zone data has a normalized name (lower case), we need to make the name of the
%% geo group lower case as well so we can properly select it.
%% @end
-spec create_geogroup(binary(), binary(), list(binary())) -> ok | {error, term()}.
create_geogroup(Name, Country, Regions) ->
    NormalizedName = normalize_name(Name),
    Pattern = #geolocation{name = NormalizedName, continent = '_', country = '_', regions = '_'},
    case erldns_storage:select(geolocation, Pattern, 0) of
        [] ->
            StoredRegions = lists:foldl(fun({{_Continent,_Country, Region}, _Name}, Acc) ->
                                                              [Region | Acc]
                                                      end, [], list_lookup_table()),
            case no_duplicate_region(Regions, StoredRegions) of
                true ->
                    NewGeo = #geolocation{name = NormalizedName,
                                          continent = proplists:get_value(Country, ?COUNTRY_CODES),
                                          country = Country, regions = Regions},
                    erldns_storage:insert(geolocation, NewGeo),
                    add_to_lookup_table(NormalizedName, NewGeo#geolocation.continent, Country, Regions);
                false ->
                    {error, duplicate_region}
            end;
        _ ->
            {error, already_exists}
    end.

%% @doc Deletes a geogroup from the DB.
-spec delete_geogroup(binary()) -> ok | {error, term()}.
delete_geogroup(Name) ->
    NormalizedName = normalize_name(Name),
    erldns_storage:delete(geolocation, NormalizedName),
    delete_from_lookup_table(NormalizedName).

%% @doc Takes the name of the geogroup to be modified, and a new list of region(s) to add to it.
-spec update_geogroup(binary(), list(binary())) -> ok | {error, term()}.
update_geogroup(Name, NewRegion) ->
    NormalizedName = normalize_name(Name),
    case erldns_storage:select(geolocation, NormalizedName) of
        [{_Name, Geo}] ->
            StoredRegions = lists:flatten(lists:foldl(fun({{_Continent,_Country, Region}, Name0}, Acc) ->
                                                              case Name0 =/= NormalizedName of
                                                                  true ->
                                                                      [Region | Acc];
                                                                  false ->
                                                                      Acc
                                                              end
                                                      end, [], list_lookup_table())),
            case no_duplicate_region(NewRegion, StoredRegions) of
                true ->
                    erldns_storage:delete(geolocation, NormalizedName),
                    erldns_storage:insert(geolocation, Geo#geolocation{regions = NewRegion}),
                    update_lookup_table(NormalizedName, NewRegion);
                false ->
                    {error, duplicate_region}
            end;
        _ ->
            {error, doesnt_exist}
    end.

list_geogroups() ->
    Pattern = #geolocation{name = '_', continent = '_', country = '_', regions = '_'},
    erldns_storage:select(geolocation, Pattern, 0).

%% gen_server hooks
init([Port, ListenIP]) ->
    {ok, #state{port = Port, listen_ip = ListenIP}}.

handle_call(_Request, _From, State) ->
    {ok, State}.

handle_cast({add_zone, Zone, SlaveIPs}, #state{listen_ip = BindIP} = State) ->
    [begin
         {ok, Socket} = gen_tcp:connect(IP, ?ADMIN_PORT, [binary, {active, false}, {ip, BindIP}]),
         ZoneBin = term_to_binary(Zone),
         {Key, Vector} = erldns_config:get_crypto(),
         Message = erldns_crypto:encrypt(Key, Vector, ZoneBin),
         ok = gen_tcp:send(Socket, <<"add_zone_", Message/binary>>),
         gen_tcp:close(Socket)
     end || IP <- SlaveIPs],
    {noreply, State};
handle_cast({delete_zone, ZoneName, SlaveIPs}, #state{listen_ip = BindIP} = State) ->
    [begin
         {ok, Socket} = gen_tcp:connect(IP, ?ADMIN_PORT, [binary, {active, false}, {ip, BindIP}]),
         ok = gen_tcp:send(Socket, <<"delete_zone_", ZoneName/binary>>),
         gen_tcp:close(Socket)
     end || IP <- SlaveIPs],
    {noreply, State};
handle_cast(_Message, State) ->
    erldns_log:info("Some other message: ~p", [_Message]),
    {noreply, State}.

handle_info({tcp, Socket, <<"slave_startup_",  IP0/binary>>}, State) ->
    IP = binary_to_term(IP0),
    {ok, {SocketIP, _SocketPort}} = inet:peername(Socket),
    case  SocketIP =:= IP of
        true ->
            gen_tcp:send(Socket, term_to_binary(erldns_zone_cache:get_zones_for_slave(IP)));
        false ->
            erldns_log:warning("Possible intruder requested zone: ~p", [{SocketIP, _SocketPort}]),
            gen_tcp:close(Socket)
    end,
    {noreply, State};
handle_info({tcp, Socket, <<"delete_zone_", ZoneName/binary>>}, State) ->
    {ok, {SocketIP, _SocketPort}} = inet:peername(Socket),
    case SocketIP =:= erldns_config:get_master_ip() of
        true ->
            gen_server:cast(erldns_manager, {delete_zone_from_orddict, ZoneName}),
            erldns_zone_cache:delete_zone(ZoneName);
        false ->
            erldns_log:warning("Possible intruder requested zone delete: ~p", [{SocketIP, _SocketPort}])
    end,
    {noreply, State};
handle_info({tcp, Socket, <<"add_zone_", EncryptedZone/binary>>}, State) ->
    {ok, {SocketIP, _SocketPort}} = inet:peername(Socket),
    case SocketIP =:= erldns_config:get_master_ip() of
        true ->
            {Key, Vector} = erldns_config:get_crypto(),
            Zone0 = erldns_crypto:decrypt(Key, Vector, EncryptedZone),
            Zone = binary_to_term(Zone0),
            erldns_zone_cache:put_zone(Zone#zone.name, Zone),
            {ok, {BindIP, _Port}} = inet:sockname(Socket),
            gen_server:cast(erldns_manager, {send_axfr, {Zone#zone.name, BindIP}}),
            gen_server:cast(erldns_manager, {add_zone_to_orddict, {Zone, BindIP}});
        false ->
            erldns_log:warning("Possible intruder requested zone add: ~p", [{SocketIP, _SocketPort}])
    end,
    {noreply, State};
%% TEST FUNCTIONS---------------------------
handle_info({tcp, _Socket, <<"test_delete_zone_", ZoneName/binary>>}, State) ->
    case erldns_config:is_test() of
        true ->
            erldns_zone_cache:delete_zone_permanently(ZoneName);
        false ->
            ok
    end,
    {noreply, State};
handle_info({tcp, _Socket, <<"test_add_zone_", Zone0/binary>>}, State) ->
    case erldns_config:is_test() of
        true ->
            Zone = binary_to_term(Zone0),
            erldns_zone_cache:add_new_zone(Zone#zone.name, Zone);
        false ->
            ok
    end,
    {noreply, State};
%% TEST FUNCTIONS---------------------------
handle_info(_Message, State) ->
    erldns_log:info("some other message ~p", [_Message]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

sock_opts() ->
    [binary].

new_connection(Socket, State) ->
    inet:setopts(Socket, [{active, once}]),
    {ok, State}.

code_change(_PreviousVersion, State, _Extra) ->
    {ok, State}.

%% Private functions
%% @doc Takes a list of regions and checks to see if there are any duplicates in the stored regions.
-spec no_duplicate_region(list(binary()), list(binary())) -> true | false.
no_duplicate_region(Regions, StoredRegions) ->
    try [false = lists:member(X, StoredRegions) || X <- Regions] of
        _NoDuplicates -> true
    catch
        error:_X ->
            false
    end.

normalize_name(Name) when is_list(Name) -> bin_to_lower(list_to_binary(Name));
normalize_name(Name) when is_binary(Name) -> bin_to_lower(Name).

%% @doc Takes a binary arguments, and transforms it to lower case. Self said!
-spec bin_to_lower(Bin :: binary()) -> binary().
bin_to_lower(Bin) ->
    bin_to_lower(Bin, <<>>).

bin_to_lower(<<>>, Acc) ->
    Acc;
bin_to_lower(<<H, T/binary>>, Acc) when H >= $A, H =< $Z ->
    H2 = H + 32,
    bin_to_lower(T, <<Acc/binary, H2>>);
bin_to_lower(<<H, T/binary>>, Acc) ->
    bin_to_lower(T, <<Acc/binary, H>>).

%% Lookup table functions
create_lookup_table() ->
    ok = erldns_storage:create(lookup_table),
    Pattern = #geolocation{name = '_', continent = '_', country = '_', regions = '_'},
    [add_subregions(Geo#geolocation.continent, Geo#geolocation.country, Geo#geolocation.regions, Geo#geolocation.name)
     || Geo <- erldns_storage:select(geolocation, Pattern, 0)].

add_to_lookup_table(Name, Continent, Country, Regions) ->
    ok = erldns_storage:create(lookup_table),
    add_subregions(Continent, Country, Regions, Name).

update_lookup_table(NormalizedName, NewRegion) ->
    ok = erldns_storage:create(lookup_table),
    delete_from_lookup_table(NormalizedName),
    [{_Name, Geo}] = erldns_storage:select(geolocation, NormalizedName),
    add_subregions(Geo#geolocation.continent, Geo#geolocation.country, NewRegion, Geo#geolocation.name).

delete_from_lookup_table(NormalizedName) ->
    ok = erldns_storage:create(lookup_table),
    erldns_storage:delete(lookup_table, NormalizedName).

list_lookup_table() ->
    ok = erldns_storage:create(lookup_table),
    ets:tab2list(lookup_table).

add_subregions(Continent, Country, Regions, Name) ->
    [erldns_storage:insert(lookup_table, {{Continent, Country, SubRegion}, Name}) || SubRegion <- Regions].
