NVIM ?= nvim
PLENARY := .tests/plenary.nvim
MINIMAL := tests/minimal_init.lua

.PHONY: all test test-file lint format perf hooks deps clean

all: lint test

## hooks -- enforce Conventional Commits. Run once per clone; git does not version
## hooks itself, so a tracked directory plus this config is the only thing that carries.
hooks:
	@git config core.hooksPath .githooks
	@echo "core.hooksPath -> .githooks"

## test  -- run the whole suite, one Neovim per spec file
test: deps
	@$(NVIM) --headless --noplugin -u $(MINIMAL) \
		-c "PlenaryBustedDirectory tests/codereview/ { minimal_init = '$(MINIMAL)', timeout = 120000 }"

## test-file FILE=tests/codereview/diff_spec.lua  -- run one spec, in-process
##
## Note: not `PlenaryBustedFile`, which spawns a child *without* -u and so loads the
## user's real config instead of the minimal one.
test-file: deps
	@test -n "$(FILE)" || { echo "usage: make test-file FILE=tests/codereview/<name>_spec.lua"; exit 2; }
	@$(NVIM) --headless --noplugin -u $(MINIMAL) \
		-c "lua require('plenary.busted').run(vim.fn.fnamemodify('$(FILE)', ':p'))"

## lint  -- stylua.toml sets syntax = "Lua52", which is what allows goto/::label::
lint:
	@stylua --check lua/ tests/

format:
	@stylua lua/ tests/

## perf  -- open, scroll, keystroke and repaint timings at 60 files and at 300. Only the
## 60-file open is budgeted; the larger tier reports. Not part of `make test`.
perf:
	@$(NVIM) --headless -u NONE -l tests/perf.lua

deps: $(PLENARY)
$(PLENARY):
	@git clone --filter=blob:none --depth 1 https://github.com/nvim-lua/plenary.nvim $@

clean:
	@rm -rf .tests
