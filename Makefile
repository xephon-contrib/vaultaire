all: build

#
# Top-level targets. This is ugly. A program to extract these from the .cabal
# file would work, but is there anything easier?
#

vault: dist/build/vault/vault
inspect: dist/build/inspect/inspect
demowave: dist/build/demowave/demowave
daemon-test: dist/build/daemon-test/daemon-test
reader-test: dist/build/reader-test/reader-test
reader-algorithms: dist/build/reader-algorithms/reader-algorithms
writer-test: dist/build/writer-test/writer-test
daymap-test: dist/build/daymap-test/daymap-test
writer-test: dist/build/writer-test/writer-test
contents-test: dist/build/contents-test/contents-test
integration-test: dist/build/integration-test/integration-test
client-server-test: dist/build/client-server-test/client-server-test
internal-store-test: dist/build/internal-store-test/internal-store-test
writer-bench: dist/build/writer-bench/writer-bench
reader-bench: dist/build/reader-bench/reader-bench


#
# Setup
#

ifdef V
MAKEFLAGS=-R
else
MAKEFLAGS=-s -R
REDIRECT=2>/dev/null
endif

.PHONY: all build test

#
# Build rules. This just wraps Cabal doing its thing in a Haskell
# language-specific fashion.
#

build: dist/setup-config tags
	@/bin/echo -e "CABAL\tbuild"
	cabal build

test: dist/setup-config tags
	@/bin/echo -e "CABAL\ttest"
	cabal test

dist/setup-config: vaultaire.cabal Setup.hs
	cabal configure \
		--enable-tests \
		--disable-benchmarks \
		-v0 2>/dev/null || /bin/echo -e "CABAL\tinstall --only-dependencies" && cabal install --only-dependencies --enable-tests --disable-benchmarks
	@/bin/echo -e "CABAL\tconfigure"
	cabal configure \
		--enable-tests \
		--disable-benchmarks \
		--disable-library-profiling \
		--disable-executable-profiling


# This will match writer-test/writer-test, so we have to strip the directory
# portion off. Annoying, but you can't use two '%' in a pattern rule.
dist/build/%: dist/setup-config tags $(SOURCES)
	@/bin/echo -e "CABAL\tbuild $@"
	cabal build $(notdir $@)

#
# Build ctags file
#

SOURCES=$(shell find src -name '*.hs' -type f) \
	$(shell find tests -name '*.hs' -type f) \
	$(shell find lib -name '*.hs' -type f)

HOTHASKTAGS=$(shell which hothasktags 2>/dev/null)
CTAGS=$(if $(HOTHASKTAGS),$(HOTHASKTAGS),/bin/false)

tags: $(SOURCES)
	if [ "$(HOTHASKTAGS)" ] ; then /bin/echo -e "CTAGS\ttags" ; fi
	-$(CTAGS) $^ > tags $(REDIRECT)

format: $(SOURCES)
	stylish-haskell -i $^

clean:
	@/bin/echo -e "CABAL\tclean"
	-cabal clean >/dev/null
	@/bin/echo -e "RM\ttemporary files"
	-rm -f tags
	-rm -f *.prof
	-rm -f src/Package.hs

doc:
	cabal haddock

install:
	cabal install
