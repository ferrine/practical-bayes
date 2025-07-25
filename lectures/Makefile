%.pdf: %.tex
	pdflatex $<
	bibtex ${*}
	pdflatex $<
	pdflatex $<

clean:
	rm -f *.aux *.bbl *.blg *.log *.out *.toc *.snm *.nav
