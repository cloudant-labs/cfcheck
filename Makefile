.PHONY: package lint-package man

PROJECT = cfcheck
BUILD_ROOT := $(PWD)/debian
BUILD := $(BUILD_ROOT)/usr
SEMVER := $(shell git describe --tags --long --dirty --always | \
	sed 's/\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)-\?.*-\([0-9]*\)-\(.*\)/\1 \2 \3 \4 \5/g')
VERSION_MAJOR := $(word 1, $(SEMVER))
VERSION_MINOR := $(word 2, $(SEMVER))
VERSION_PATCH := $(word 3, $(SEMVER))
ifeq ($(strip $(VERSION_MINOR)),)
VERSION := $(shell git describe --tags --long --always)
else
VERSION := "$(VERSION_MAJOR).$(VERSION_MINOR).$(VERSION_PATCH)"
endif
export DEBFULLNAME := $(shell git log --pretty --format="%cn" -1 $(VERSION))
export DEBEMAIL := $(shell git log --pretty --format="%ce" -1 $(VERSION))

PACKAGE := "cfcheck_$(VERSION)-1_amd64.deb"

DEPS = getopt jiffy snappy
dep_getopt = git https://github.com/jcomellas/getopt master
dep_jiffy = git https://github.com/davisp/jiffy master
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

clean::
	@rm -rf $(PWD)/priv

distclean::
	@rm -rf $(PWD)/priv

package:
	@if test -d $(BUILD_ROOT); then rm -rf $(BUILD_ROOT); fi
	@mkdir -p $(BUILD_ROOT)/DEBIAN
	@mkdir -p $(BUILD)/bin
	@mkdir -p $(BUILD)/lib/cfcheck
	@mkdir -p $(BUILD)/share/man/man1
	@mkdir -p $(BUILD)/share/doc/cfcheck
	@cp $(PWD)/cfcheck $(BUILD)/bin
	@(cd $(BUILD)/bin && ln -s ../lib/cfcheck $(BUILD)/bin/priv)
	@cp $(PWD)/priv/jiffy.so $(BUILD)/lib/cfcheck/jiffy.so
	@objcopy --strip-debug --strip-unneeded $(BUILD)/lib/cfcheck/jiffy.so
	@cp $(PWD)/priv/snappy_nif.so $(BUILD)/lib/cfcheck/snappy_nif.so
	@objcopy --strip-debug --strip-unneeded $(BUILD)/lib/cfcheck/snappy_nif.so
	@<$(PWD)/build/control awk -v VERSION="$(VERSION)" '{gsub(/VERSION/, VERSION); print}' > $(BUILD_ROOT)/DEBIAN/control
	@cp $(PWD)/man/cfcheck.1 $(BUILD)/share/man/man1
	@gzip --best $(BUILD)/share/man/man1/cfcheck.1
	@echo "Files: $(BUILD)/bin/cfcheck" > $(BUILD)/share/doc/cfcheck/copyright
	@echo "Copyright: 2015 IBM Corporation" >> $(BUILD)/share/doc/cfcheck/copyright
	@echo "License: Apache-2.0]\n On Debian systems the full text of the Apache-2.0 license can be found in the\n '/usr/share/common-licenses/Apache-2.0' file." >> $(BUILD)/share/doc/cfcheck/copyright
	@dch --create --package cfcheck --newversion $(VERSION) --urgency low --changelog $(BUILD)/share/doc/cfcheck/changelog Initial commit
	@git log --reverse --format="%s" 0fbb9f3..$(VERSION) | xargs -L 1 dch -i --changelog $(BUILD)/share/doc/cfcheck/changelog
	@cp $(BUILD)/share/doc/cfcheck/changelog $(BUILD)/share/doc/cfcheck/changelog.Debian
	@gzip --best $(BUILD)/share/doc/cfcheck/changelog
	@gzip --best $(BUILD)/share/doc/cfcheck/changelog.Debian
	@fakeroot dpkg-deb --build $(BUILD_ROOT)
	@mv debian.deb $(PWD)/build/$(PACKAGE)
	@rm -rf $(BUILD_ROOT)

lint-package:
	@lintian $(PWD)/build/$(PACKAGE)

man:
	@ronn --roff $(PWD)/man/*.md
