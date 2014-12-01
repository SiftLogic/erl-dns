.PHONY: all test clean

all: clean build-all

build-all:
	./rebar get-deps compile

build-deps:
	./rebar get-deps

clean-deps:
	rm -rf deps/*

build:
	./rebar compile

get-deps:
	./rebar get-deps

clean:
	./rebar clean

clean-deps:
	rm -rf deps/*

clean-all:
	rm -rf deps/*
	./rebar clean

dialyzer-init:
	dialyzer --build-plt --apps erts kernel stdlib

dialyzer:
	dialyzer -r src --src

test:
	rm -f test/*beam
	./rebar compile
	ct_run -config erldns.config -dir test -suite erldns_SUITE -logdir test_logs -pa ebin deps/**/ebin/ -s erldns

test-clean-run:
	rm -f test/*beam
	./rebar clean compile
	ct_run -dir test -suite erldns_SUITE -logdir test_logs -pa ebin/ deps/*/ebin/*

test-clean:
	rm -rf logs/*
	./rebar clean

run:
	erl -config erldns.config -pa ebin deps/**/ebin -s erldns
