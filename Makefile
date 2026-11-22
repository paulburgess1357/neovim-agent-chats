NVIM ?= nvim
RUN = $(NVIM) --clean --headless --cmd 'set columns=160 lines=48' -c 'luafile tests/run.lua'

.PHONY: test lint format

# make test            every spec
# make test SPEC=codex one spec file
# make test FILTER=... tests whose name contains the text
test:
	@SPEC='$(SPEC)' FILTER='$(FILTER)' $(RUN)

# shellcheck and node are used when they are there; stylua is required.
lint:
	stylua --check lua plugin tests
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh scripts/agent-chats-hook.sh && echo 'shellcheck: ok'; fi
	@if command -v node >/dev/null 2>&1; then node --check scripts/opencode-agent-chats.js && echo 'node --check: ok'; fi

# Twice: one pass of stylua does not always leave what a second would.
format:
	stylua lua plugin tests
	stylua lua plugin tests
