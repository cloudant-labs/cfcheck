PROJECT = cfcheck

DEPS = getopt jiffy snappy
dep_snappy = git https://github.com/fdmanana/snappy-erlang-nif master

ESCRIPT_EMU_ARGS ?= -pa . \
	-sasl false \
	-kernel error_logger silent \
	-escript main $(ESCRIPT_NAME)

include erlang.mk

all:: escript

escript::
	@mkdir -p $(PWD)/priv
	@cp $(PWD)/deps/snappy/priv/snappy_nif.so $(PWD)/priv
	@cp $(PWD)/deps/jiffy/priv/jiffy.so $(PWD)/priv