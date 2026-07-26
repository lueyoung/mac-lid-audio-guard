.PHONY: build test install status uninstall

build:
	./scripts/build.sh

test:
	./scripts/test.sh

install:
	./scripts/install.sh

status:
	./scripts/status.sh

uninstall:
	./scripts/uninstall.sh

