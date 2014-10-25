.PHONY: all compile deps clean distclean test check_plt build_plt dialyzer \
	    cleanplt

all: deps compile

compile: deps
	./rebar compile

deps:
	test -d deps || ./rebar get-deps

clean:
	./rebar clean

distclean: clean
	./rebar delete-deps

DIALYZER_APPS = kernel stdlib erts sasl eunit syntax_tools compiler crypto \
				common_test

include tools.mk
