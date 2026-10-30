.PHONY: all clean

PAPER = paper

# The build uses tectonic when it is installed (it runs BibTeX itself, in one
# command), and pdflatex + bibtex otherwise. With neither, the build fails.
TECTONIC := $(shell command -v tectonic 2>/dev/null)

all: $(PAPER).pdf

$(PAPER).pdf: $(PAPER).tex preamble.tex references.bib $(wildcard sections/*.tex)
ifneq ($(TECTONIC),)
	tectonic $(PAPER).tex
else
	pdflatex $(PAPER)
	bibtex $(PAPER)
	pdflatex $(PAPER)
	pdflatex $(PAPER)
endif

clean:
	rm -f $(PAPER).aux $(PAPER).bbl $(PAPER).blg $(PAPER).log $(PAPER).out $(PAPER).toc $(PAPER).pdf
