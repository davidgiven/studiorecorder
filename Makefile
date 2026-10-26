PYTHON ?= python3

.PHONY: run test

run:
	$(PYTHON) -m studio_recorder

test:
	$(PYTHON) -m unittest discover -s tests -v
