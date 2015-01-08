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

%% @doc This file is for default region values and all geo-location related functions.

-module(erldns_georegion).

-include("erldns.hrl").
%% API
-export([start/0,
         load_defaults/0]).

-export([create_geogroup/3,
         delete_geogroup/1,
         update_geogroup/2]).

-export([create_lookup_table/0]).

start() ->
    case erldns_storage:create(geolocation) of
        ok ->
            ok = erldns_storage:create(lookup_table),
            generate_default_db();
        exists ->
            create_lookup_table()
    end,
    ok.

load_defaults() ->
    erldns_storage:empty_table(geolocation),
    erldns_storage:empty_table(lookup_table),
    generate_default_db(),
    create_lookup_table().

generate_default_db() ->
    create_geogroup(<<"us-west">>, <<"US">>, [
                                              <<"WA">>, <<"OR">>, <<"CA">>, <<"AK">>, <<"HI">>,
                                              <<"ID">>, <<"NV">>, <<"MT">>, <<"WY">>, <<"CO">>,
                                              <<"NM">>, <<"UT">>, <<"AZ">>
                                             ]),
    create_geogroup(<<"us-central">>, <<"US">>, [
                                                 <<"ND">>, <<"SD">>, <<"NE">>, <<"KS">>, <<"OK">>,
                                                 <<"TX">>, <<"MN">>, <<"IA">>, <<"MO">>, <<"AR">>,
                                                 <<"LA">>, <<"MI">>, <<"WI">>, <<"IL">>, <<"KY">>,
                                                 <<"TN">>, <<"MS">>, <<"IN">>, <<"OH">>
                                                ]),
    create_geogroup(<<"us-east">>, <<"US">>, [
                                              <<"AL">>, <<"FL">>, <<"GA">>, <<"SC">>, <<"NC">>,
                                              <<"VA">>,<<"WV">>, <<"MD">>, <<"DE">>, <<"NJ">>,
                                              <<"PA">>, <<"NY">>, <<"CT">>, <<"RI">>, <<"MA">>,
                                              <<"NH">>, <<"ME">>, <<"VT">>
                                             ]),
    create_geogroup(<<"canada">>, <<"CA">>, [
                                             <<"AB">>, <<"BC">>, <<"MB">>, <<"NB">>, <<"NL">>,
                                             <<"NT">>, <<"NS">>, <<"NU">>, <<"ON">>, <<"PE">>,
                                             <<"QC">>, <<"SK">>, <<"YT">>, <<>>]),
    create_geogroup(<<"europe">>, <<"EU">>, [<<"EU">>]).

%% Geo-location API
%% @doc Adds a new geogroup to the DB.
%% NOTE: Because zone data has a normalized name (lower case), we need to make the name of the
%% geo group lower case as well so we can properly select it.
%% @end
-spec create_geogroup(binary(), binary(), list(binary())) -> ok | {error, term()}.
create_geogroup(Name, Country, Regions) ->
    NormalizedName = normalize_name(Name),
    case lists:keyfind(NormalizedName, 2, erldns_storage:list_table(lookup_table)) of
        false ->
            StoredRegions = lists:foldl(fun({{_Continent,_Country, Region}, _Name}, Acc) ->
                                                [Region | Acc]
                                        end, [], erldns_storage:list_table(lookup_table)),
            case no_duplicate_region(Regions, StoredRegions) of
                true ->
                    NewGeo = #geolocation{name = NormalizedName,
                                          continent = erldns_config:keyget(Country, ?COUNTRY_CODES),
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
    case erldns_storage:select(geolocation, NormalizedName) of
        [{_Name, #geolocation{continent = Continent, country = Country, regions = OldRegion}}] ->
            erldns_storage:delete(geolocation, NormalizedName),
            delete_from_lookup_table(Continent, Country, OldRegion);
        _ ->
            {error, doesnt_exist}
    end.

%% @doc Takes the name of the geogroup to be modified, and a new list of region(s) to add to it.
-spec update_geogroup(binary(), list(binary())) -> ok | {error, term()}.
update_geogroup(Name, NewRegion) ->
    NormalizedName = normalize_name(Name),
    case erldns_storage:select(geolocation, NormalizedName) of
        [{_Name, #geolocation{continent = Continent, country = Country, regions = OldRegion} = Geo}] ->
            StoredRegions = lists:flatten(lists:foldl(fun({{_Continent,_Country, Region}, Name0}, Acc) ->
                                                              case Name0 =/= NormalizedName of
                                                                  true ->
                                                                      [Region | Acc];
                                                                  false ->
                                                                      Acc
                                                              end
                                                      end, [], erldns_storage:list_table(lookup_table))),
            case no_duplicate_region(NewRegion, StoredRegions) of
                true ->
                    erldns_storage:delete(geolocation, NormalizedName),
                    erldns_storage:insert(geolocation, Geo#geolocation{regions = NewRegion}),
                    update_lookup_table(NormalizedName, NewRegion, {Continent, Country, OldRegion});
                false ->
                    {error, duplicate_region}
            end;
        _ ->
            {error, doesnt_exist}
    end.

%% Private functions
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

%% @doc Takes a list of regions and checks to see if there are any duplicates in the stored regions.
-spec no_duplicate_region(list(binary()), list(binary())) -> true | false.
no_duplicate_region(Regions, StoredRegions) ->
    try [false = lists:member(X, StoredRegions) || X <- Regions] of
        _NoDuplicates -> true
    catch
        error:_X ->
            false
    end.

%% Lookup table functions
create_lookup_table() ->
    ok = erldns_storage:create(lookup_table),
    [add_subregions(Geo#geolocation.continent, Geo#geolocation.country, Geo#geolocation.regions, Geo#geolocation.name)
     || Geo <- erldns_storage:list_table(geolocation)].

add_to_lookup_table(Name, Continent, Country, Regions) ->
    ok = erldns_storage:create(lookup_table),
    add_subregions(Continent, Country, Regions, Name).

update_lookup_table(NormalizedName, NewRegion, {Continent, Country, OldRegion}) ->
    ok = erldns_storage:create(lookup_table),
    delete_from_lookup_table(Continent, Country, OldRegion),
    add_subregions(Continent, Country, NewRegion, NormalizedName).

delete_from_lookup_table(Continent, Country, Regions) ->
    ok = erldns_storage:create(lookup_table),
    [erldns_storage:delete(lookup_table, {Continent, Country, Region}) || Region <- Regions].

add_subregions(Continent, Country, Regions, Name) ->
    ok = erldns_storage:create(lookup_table),
    [erldns_storage:insert(lookup_table, {{Continent, Country, SubRegion}, Name}) || SubRegion <- Regions].