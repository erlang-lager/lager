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

test:
	./rebar compile eunit

##
## Doc targets
##
docs:
	./rebar doc

APPS = kernel stdlib erts sasl eunit syntax_tools compiler crypto
PLT ?= $(HOME)/.riak_combo_dialyzer_plt
LOCAL_PLT = .lager_combo_dialyzer_plt

${PLT}: compile
ifneq (,$(wildcard $(PLT)))
	dialyzer --check_plt --plt $(PLT) --apps $(APPS) && \
		dialyzer --add_to_plt --plt $(PLT) --output_plt $(PLT) --apps $(APPS) ; test $$? -ne 1
else
	dialyzer --build_plt --output_plt $(PLT) --apps $(APPS); test $$? -ne 1
endif

${LOCAL_PLT}: compile
ifneq (,$(wildcard $(LOCAL_PLT)))
	dialyzer --check_plt --plt $(LOCAL_PLT) deps/*/ebin  && \
		dialyzer --add_to_plt --plt $(LOCAL_PLT) --output_plt $(LOCAL_PLT) deps/*/ebin ; test $$? -ne 1
else
	dialyzer --build_plt --output_plt $(LOCAL_PLT) deps/*/ebin ; test $$? -ne 1
endif

dialyzer: ${PLT} ${LOCAL_PLT}
	dialyzer -Wunmatched_returns --plts $(PLT) $(LOCAL_PLT) -c ebin

cleanplt:
	@echo 
	@echo "Are you sure?  It takes several minutes to re-build."
	@echo Deleting $(PLT) and $(LOCAL_PLT) in 5 seconds.
	@echo 
	sleep 5
	rm $(PLT)
	rm $(LOCAL_PLT)

