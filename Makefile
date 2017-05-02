VERSION := 0.0.0

progname := ngless
distdir := ngless-${VERSION}

prefix=/usr/local
deps=$(prefix)/share/$(progname)
exec=$(prefix)/bin


BWA_DIR = bwa-0.7.15
BWA_URL = https://github.com/lh3/bwa/releases/download/v0.7.15/bwa-0.7.15.tar.bz2
BWA_TAR = bwa-0.7.15.tar.bz2
BWA_TARGET = ngless-bwa

SAM_DIR = samtools-1.4
SAM_URL = https://github.com/samtools/samtools/releases/download/1.4/samtools-1.4.tar.bz2
SAM_TAR = samtools-1.4.tar.bz2
SAM_TARGET = ngless-samtools

MEGAHIT_DIR = megahit-1.1.1
MEGAHIT_TAR = v1.1.1.tar.gz
MEGAHIT_URL = https://github.com/voutcn/megahit/archive/v1.1.1.tar.gz
MEGAHIT_TARGET = ngless-megahit

NGLESS_EMBEDDED_BINARIES := \
		NGLess/Dependencies/samtools_data.c \
		NGLess/Dependencies/bwa_data.c \
		NGLess/Dependencies/megahit_data.c

HTML = Html
HTML_LIBS_DIR = $(HTML)/htmllibs
HTML_FONTS_DIR = $(HTML)/fonts

# Required html Librarys
HTMLFILES := jquery-latest.min.js
HTMLFILES += angular.min.js
HTMLFILES += bootstrap.min.css
HTMLFILES += bootstrap-theme.min.css
HTMLFILES += bootstrap.min.js
HTMLFILES += d3.min.js
HTMLFILES += nv.d3.js
HTMLFILES += nv.d3.css
HTMLFILES += angular-sanitize.js
HTMLFILES += bootstrap-glyphicons.css
HTMLFILES += angular-animate.min.js

# Required fonts
FONTFILES := glyphicons-halflings-regular.woff
FONTFILES += glyphicons-halflings-regular.ttf

#URLS
jquery-latest.min.js = code.jquery.com/jquery-latest.min.js
d3.min.js = cdnjs.cloudflare.com/ajax/libs/d3/3.1.6/d3.min.js
nv.d3.js = cdnjs.cloudflare.com/ajax/libs/nvd3/1.1.14-beta/nv.d3.js
nv.d3.css = cdnjs.cloudflare.com/ajax/libs/nvd3/1.1.14-beta/nv.d3.css
angular-sanitize.js = code.angularjs.org/1.3.0-beta.1/angular-sanitize.js
bootstrap.min.js = netdna.bootstrapcdn.com/bootstrap/3.0.2/js/bootstrap.min.js
bootstrap.min.css = netdna.bootstrapcdn.com/bootstrap/3.0.2/css/bootstrap.min.css
angular.min.js = ajax.googleapis.com/ajax/libs/angularjs/1.3.0-beta.1/angular.min.js
bootstrap-glyphicons.css += netdna.bootstrapcdn.com/bootstrap/3.0.0/css/bootstrap-glyphicons.css
bootstrap-theme.min.css = netdna.bootstrapcdn.com/bootstrap/3.0.2/css/bootstrap-theme.min.css
glyphicons-halflings-regular.woff = netdna.bootstrapcdn.com/bootstrap/3.0.0/fonts/glyphicons-halflings-regular.woff
glyphicons-halflings-regular.ttf = netdna.bootstrapcdn.com/bootstrap/3.0.0/fonts/glyphicons-halflings-regular.ttf
angular-animate.min.js = ajax.googleapis.com/ajax/libs/angularjs/1.2.16/angular-animate.min.js

reqhtmllibs = $(addprefix $(HTML_LIBS_DIR)/, $(HTMLFILES))
reqfonts = $(addprefix $(HTML_FONTS_DIR)/, $(FONTFILES))

all: ngless

NGLess.cabal: NGLess.cabal.m4
	m4 $< > $@

ngless-embed: NGLess.cabal modules $(NGLESS_EMBEDDED_BINARIES)
	stack build $(STACKOPTS) --flag NGLess:embed

ngless: NGLess.cabal modules
	stack build $(STACKOPTS)

modules:
	cd Modules && $(MAKE)

static: NGLess.cabal modules $(NGLESS_EMBEDDED_BINARIES)
	stack build $(STACKOPTS) --ghc-options='-optl-static -optl-pthread' --force-dirty --flag NGLess:embed

fast: NGLess.cabal
	stack build $(STACKOPTS) --ghc-options=-O0


dist: ngless-${VERSION}.tar.gz

testinputfiles=test_samples/htseq-res/htseq_cds_noStrand_union.txt

test_samples/htseq-res/htseq_cds_noStrand_union.txt:
	cd test_samples/ && gzip -dkf *.gz
	cd test_samples/htseq-res && ./generateHtseqFiles.sh

check: NGLess.cabal
	stack test $(STACKOPTS)

fastcheck: NGLess.cabal
	stack test $(STACKOPTS) --ghc-options=-O0
# Synonym
tests: check

bench: NGLess.cabal
	stack bench $(STACKOPTS)

profile:
	stack build $(STACKOPTS) --executable-profiling --library-profiling --ghc-options="-fprof-auto -rtsopts"

install:
	mkdir -p $(exec)
	mkdir -p $(deps)
	cp -rf $(HTML) $(deps)
	cp -rf $(BWA_DIR) $(deps)
	cp -rf $(SAM_DIR) $(deps)
	cp -f dist/build/ngless/ngless $(exec)/ngless

nglessconf: $(SAM_DIR) $(BWA_DIR) $(reqhtmllibs) $(reqfonts)

clean:
	rm -f $(NGLESS_EMBEDDED_BINARIES)
	stack clean $(STACKOPTS)

distclean: clean
	rm -rf $(HTML_FONTS_DIR) $(HTML_LIBS_DIR)
	rm -rf $(BWA_DIR)
	rm -rf $(SAM_DIR)
	rm -f test_samples/htseq-res/*.txt

uninstall:
	rm -rf $(deps) $(exec)/ngless*


$(BWA_DIR):
	wget $(BWA_URL)
	tar xvfj $(BWA_TAR)
	rm $(BWA_TAR)
	cd $(BWA_DIR) && curl https://patch-diff.githubusercontent.com/raw/lh3/bwa/pull/90.diff | patch -p1

$(BWA_DIR)/bwa: $(BWA_DIR)
	cd $(BWA_DIR) && $(MAKE)

$(BWA_DIR)/$(BWA_TARGET)-static: $(BWA_DIR)
	cd $(BWA_DIR) && $(MAKE) CFLAGS="-static"  LIBS="-lbwa -lm -lz -lrt -lpthread" && cp -p bwa $(BWA_TARGET)-static

$(SAM_DIR):
	wget $(SAM_URL)
	tar xvfj $(SAM_TAR)
	rm $(SAM_TAR)

$(SAM_DIR)/$(SAM_TARGET)-static: $(SAM_DIR)
	cd $(SAM_DIR) && ./configure --without-curses && $(MAKE) LDFLAGS="-static" DFLAGS="-DNCURSES_STATIC" && cp -p samtools $(SAM_TARGET)-static

$(SAM_DIR)/samtools: $(SAM_DIR)
	cd $(SAM_DIR) && ./configure --without-curses && $(MAKE)

$(MEGAHIT_DIR):
	wget $(MEGAHIT_URL)
	tar xvzf $(MEGAHIT_TAR)
	rm $(MEGAHIT_TAR)

$(MEGAHIT_DIR)/$(MEGAHIT_TARGET): $(MEGAHIT_DIR)
	cd $(MEGAHIT_DIR) && patch -p1 <../build-scripts/megahit-1.1.1.patch
	cd $(MEGAHIT_DIR) && $(MAKE) CXXFLAGS=-static

$(MEGAHIT_DIR)/$(MEGAHIT_TARGET)-packaged: $(MEGAHIT_DIR)/$(MEGAHIT_TARGET)
	cd $(MEGAHIT_DIR) && strip megahit_asm_core
	cd $(MEGAHIT_DIR) && strip megahit_sdbg_build
	cd $(MEGAHIT_DIR) && strip megahit_toolkit
	mkdir -p $@ && cp -pr $(MEGAHIT_DIR)/megahit_asm_core $(MEGAHIT_DIR)/megahit_sdbg_build $(MEGAHIT_DIR)/megahit_toolkit $(MEGAHIT_DIR)/megahit $@

$(MEGAHIT_DIR)/$(MEGAHIT_TARGET)-packaged.tar.gz: $(MEGAHIT_DIR)/$(MEGAHIT_TARGET)-packaged
	tar --create --file $@ --gzip $<

NGLess/Dependencies/samtools_data.c: $(SAM_DIR)/$(SAM_TARGET)-static
	strip $<
	xxd -i $< $@

NGLess/Dependencies/bwa_data.c: $(BWA_DIR)/$(BWA_TARGET)-static
	strip $<
	xxd -i $< $@

NGLess/Dependencies/megahit_data.c: $(MEGAHIT_DIR)/$(MEGAHIT_TARGET)-packaged.tar.gz
	xxd -i $< $@


# We cannot depend on $(HTML_LIBS_DIR) as wget sets the mtime in the past
# and it would cause the download to happen at every make run
$(HTML_LIBS_DIR)/%.js:
	mkdir -p $(HTML_LIBS_DIR)
	echo $(notdir $@)
	wget -O $@ $($(notdir $@))


$(HTML_LIBS_DIR)/%.css:
	mkdir -p $(HTML_LIBS_DIR)
	echo $(notdir $@)
	wget -O $@ $($(notdir $@))


$(HTML_FONTS_DIR)/%.woff:
	mkdir -p $(HTML_FONTS_DIR)
	echo $(notdir $@)
	wget -O $@ $($(notdir $@))

$(HTML_FONTS_DIR)/%.ttf:
	mkdir -p $(HTML_FONTS_DIR)
	echo $(notdir $@)
	wget -O $@ $($(notdir $@))

ngless-${VERSION}.tar.gz: ngless
	mkdir -p $(distdir)/share $(distdir)/bin
	stack build
	cp dist/build/$(progname)/$(progname) $(distdir)/bin
	cp -r $(BWA_DIR) $(distdir)/share
	cp -r $(SAM_DIR) $(distdir)/share
	cp -r $(HTML) $(distdir)/share
	tar -zcvf $(distdir).tar.gz $(distdir)
	rm -rf $(distdir)

.PHONY: all build clean check tests distclean dist static fast fastcheck modules
