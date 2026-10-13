# tingres: PostgreSQL written in Tin. TIN points at a Tin checkout (its `tin` script sets TIN_ROOT).
TIN ?= $(HOME)/dev/extra/tin/tin
BIN := bin/server

.PHONY: all build test check fmt clean client diff

all: build

build:
	mkdir -p $(BIN)
	$(TIN) build main.tin -o $(BIN)/tingres

check:
	$(TIN) check main.tin

test:
	$(TIN) test proto
	$(TIN) test server
	$(TIN) test tests

client:
	mkdir -p $(BIN)
	$(TIN) build tests/client/main.tin -o $(BIN)/client_probe

diff: build client
	./tests/diff.sh

fmt:
	$(TIN) fmt -w .

clean:
	rm -rf $(BIN)
