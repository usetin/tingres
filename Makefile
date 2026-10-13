# tingres: PostgreSQL written in Tin. TIN points at a Tin checkout (its `tin` script sets TIN_ROOT).
TIN ?= $(HOME)/dev/extra/tin/tin
BIN := bin

.PHONY: all build test check fmt clean

all: build

build:
	mkdir -p $(BIN)
	$(TIN) build main.tin -o $(BIN)/tingres

check:
	$(TIN) check main.tin

test:
	$(TIN) test .

fmt:
	$(TIN) fmt -w .

clean:
	rm -rf $(BIN)
