# tingres: PostgreSQL written in Tin. TIN points at a Tin checkout (its `tin` script sets TIN_ROOT).
TIN ?= $(HOME)/dev/extra/tin/tin
BIN := bin/server

.PHONY: all build test check fmt clean client diff concurrency protocol fuzz

all: build

build:
	mkdir -p $(BIN)
	$(TIN) build main.tin -o $(BIN)/tingres

check:
	$(TIN) check main.tin

test: build
	$(TIN) test proto
	$(TIN) test server
	$(TIN) test tests
	python3 tests/concurrency.py $(BIN)/tingres
	python3 tests/protocol.py $(BIN)/tingres

client:
	mkdir -p $(BIN)
	$(TIN) build tests/client/main.tin -o $(BIN)/client_probe

bench:
	mkdir -p $(BIN)
	$(TIN) build bench/main.tin -o $(BIN)/tingres-bench

diff: build client
	./tests/diff.sh

concurrency: build
	python3 tests/concurrency.py $(BIN)/tingres

protocol: build
	python3 tests/protocol.py $(BIN)/tingres

fuzz: build
	python3 tests/fuzz.py $(BIN)/tingres

fmt:
	$(TIN) fmt -w .

clean:
	rm -rf $(BIN)
