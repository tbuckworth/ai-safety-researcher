.PHONY: all clean

PAPER = paper

all: $(PAPER).pdf

$(PAPER).pdf: $(PAPER).tex preamble.tex references.bib $(wildcard sections/*.tex)
	pdflatex $(PAPER)
	bibtex $(PAPER)
	pdflatex $(PAPER)
	pdflatex $(PAPER)

clean:
	rm -f $(PAPER).aux $(PAPER).bbl $(PAPER).blg $(PAPER).log $(PAPER).out $(PAPER).toc $(PAPER).pdf
