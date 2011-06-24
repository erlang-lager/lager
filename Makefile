all:
	./rebar compile

clean:
	./rebar clean

test: all
	./rebar eunit
